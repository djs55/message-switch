(*
 * Copyright (c) Citrix Systems Inc.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Cohttp
open Logging
open Clock

module StringSet = Set.Make(struct type t = string let compare = String.compare end)

module StringStringRelation = Relation.Make(struct type t = string let compare = compare end)(String)

module Connections = struct
	let t = ref (StringStringRelation.empty)

	let get_session conn_id =
		(* Nothing currently stops you registering multiple sessions per connection *)
		let sessions = StringStringRelation.get_bs conn_id !t in
		if sessions = StringStringRelation.B_Set.empty
		then None
		else Some(StringStringRelation.B_Set.choose sessions)

	let get_origin conn_id = match get_session conn_id with
		| None -> Protocol.Anonymous conn_id
		| Some x -> Protocol.Name x

	let add conn_id session =
		debug "+ connection %s" conn_id;
		t := StringStringRelation.add conn_id session !t

	let remove conn_id =
		debug "- connection %s" conn_id;
		t := StringStringRelation.remove_a conn_id !t

	let is_session_active session =
		StringStringRelation.get_as session !t <> StringStringRelation.A_Set.empty

end

module Transient_queue = struct

	(* Session -> set of queues which will be GCed on session cleanup *)
	let queues : (string, StringSet.t) Hashtbl.t = Hashtbl.create 128

	let add session name =
		let existing =
			if Hashtbl.mem queues session
			then Hashtbl.find queues session
			else StringSet.empty in
		Hashtbl.replace queues session (StringSet.add name existing)

	let remove session =
		if Hashtbl.mem queues session then begin
			let qs = Hashtbl.find queues session in
			StringSet.iter
				(fun name ->
					info "Deleting transient queue: %s" name;
					Q.Directory.remove name;
				) qs;
			Hashtbl.remove queues session
		end

	let all () = Hashtbl.fold (fun _ set acc -> StringSet.union set acc) queues StringSet.empty
end

let next_transfer_expected : (string, int64) Hashtbl.t = Hashtbl.create 128
let get_next_transfer_expected name =
	if Hashtbl.mem next_transfer_expected name
	then Some (Hashtbl.find next_transfer_expected name)
	else None
let record_transfer time name =
	Hashtbl.replace next_transfer_expected name time

let snapshot () =
	let open Protocol.Diagnostics in
	let queues =
		List.fold_left (fun acc (n, q)->
			let queue_contents = Q.contents q in
			let next_transfer_expected = get_next_transfer_expected n in
			(n, { queue_contents; next_transfer_expected }) :: acc
		) [] in
	let is_transient =
		let all = Transient_queue.all () in
		fun (x, _) -> StringSet.mem x all in
	let all_queues = queues (List.map (fun n -> n, (Q.Directory.find n)) (Q.Directory.list "")) in
	let transient_queues, permanent_queues = List.partition is_transient all_queues in
	let current_time = time () in
	{ current_time; permanent_queues; transient_queues }

open Protocol
let process_request conn_id session request = match session, request with
	(* Only allow Login, Get, Trace and Diagnostic messages if there is no session *)
	| _, In.Login session ->
		(* associate conn_id with 'session' *)
		Connections.add conn_id session;
		return Out.Login
	| _, In.Diagnostics ->
		return (Out.Diagnostics (snapshot ()))
	| _, In.Trace(from, timeout) ->
		lwt events = Trace.get from timeout in
		return (Out.Trace {Out.events = events})
	| _, In.Get path ->
		let path = if path = [] || path = [ "" ] then [ "index.html" ] else path in
		lwt ic = Lwt_io.open_file ~mode:Lwt_io.input (String.concat "/" ("www" :: path)) in
		lwt txt = Lwt_stream.to_string (Lwt_io.read_chars ic) in
		lwt () = Lwt_io.close ic in
		return (Out.Get txt)
	| None, _ ->
		return Out.Not_logged_in
	| Some session, In.List prefix ->
		return (Out.List (Q.Directory.list prefix))
	| Some session, In.CreatePersistent name ->
		Q.Directory.add name;
		return (Out.Create name)
	| Some session, In.CreateTransient name ->
		Transient_queue.add session name;
		Q.Directory.add name;
		return (Out.Create name)
	| Some session, In.Destroy name ->
		Q.Directory.remove name;
		return Out.Destroy
	| Some session, In.Ack (name, id) ->
		Trace.add (Event.({time = Unix.gettimeofday (); input = Some session; queue = name; output = None; message = Ack (name, id); processing_time = None }));
		Q.ack (name, id);
		return Out.Ack
	| Some session, In.Transfer { In.from = from; timeout = timeout; queues = queues } ->
		let start = Unix.gettimeofday () in
		let from = match from with None -> -1L | Some x -> Int64.of_string x in
		let rec wait () =
			let time = Int64.add (time ()) (Int64.of_float (timeout *. 1e9)) in
			List.iter (record_transfer time) queues;
			let not_seen = Q.transfer from queues in
			if not_seen <> []
			then return not_seen
			else
				let remaining_timeout = max 0. (start +. timeout -. (Unix.gettimeofday ())) in
				if remaining_timeout <= 0.
				then return []
				else
					let timeout = Lwt.map (fun () -> `Timeout) (Lwt_unix.sleep remaining_timeout) in
					let more = List.map (fun name ->
						Lwt.map (fun () -> `Data) (Q.wait from name)
					) queues in
					try_lwt
						match_lwt Lwt.pick (timeout :: more) with
						| `Timeout -> return []
						| `Data ->
							wait ()
					finally
			   			return ()
				in
		lwt messages = wait () in
		let next = match messages with
		| [] -> from
		| x :: xs -> List.fold_left max (snd (fst x)) (List.map (fun x -> snd (fst x)) xs) in
		let transfer = {
			Out.messages = messages;
			next = Int64.to_string next
		} in
		let now = Unix.gettimeofday () in
		List.iter
			(fun (id, m) ->
				let name = Q.queue_of_id id in
				let processing_time = match m.Message.kind with
				| Message.Request _ -> None
				| Message.Response id' -> begin match Q.entry id' with
					| Some request_entry ->
						Some (Int64.sub (time ()) request_entry.Entry.time)
					| None ->
						None
				end in
				Trace.add (Event.({time = now; input = None; queue = name; output = Some session; message = Message (id, m); processing_time }))
			) transfer.Out.messages;
		return (Out.Transfer transfer)
	| Some session, In.Send (name, data) ->
		let origin = Connections.get_origin conn_id in
		begin match_lwt Q.send origin name data with
		| None -> return (Out.Send None)
		| Some id ->
			Trace.add (Event.({time = Unix.gettimeofday (); input = Some session; queue = name; output = None; message = Message (id, data); processing_time = None }));
			return (Out.Send (Some id))
		end
