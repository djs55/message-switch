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

open Protocol
open Cohttp


let with_lock m f =
  Mutex.lock m;
  try
    let r = f () in
    Mutex.unlock m;
    r
  with e ->
    Mutex.unlock m;
    raise e

module IO = struct

  let whoami () = Printf.sprintf "%s:%d"
    (Filename.basename Sys.argv.(0)) (Unix.getpid ())

  module IO = struct
	type 'a t = 'a
	let ( >>= ) a f = f a
	let (>>) m n = m >>= fun _ -> n

	let return a = a

	let iter = List.iter

	type ic = in_channel
	type oc = out_channel
        type conn = unit

	let read_line ic =
		try
			let line = input_line ic in
			let last = String.length line - 1 in
			let line = if line.[last] = '\r' then String.sub line 0 last else line in
			Some line
		with _ -> None

	let read_into_exactly ic buf ofs len =
		try
			really_input ic buf ofs len; true
		with _ -> false
	let read_exactly ic len =
		let buf = String.create len in
		read_into_exactly ic buf 0 len >>= function
		| true -> return (Some buf)
		| false -> return None

	let read ic n =
		let buf = String.make n '\000' in
		let actually_read = input ic buf 0 n in
		if actually_read = n
		then buf
		else String.sub buf 0 actually_read

	let write oc x =
		output_string oc x; flush oc

	let connect port =
		let sockaddr = Unix.ADDR_INET(Unix.inet_addr_of_string "127.0.0.1", port) in
		let result = ref None in
		while !result = None do
      (* The system may invalidate the socket after a connect failure, therefore
         we must create a fresh fd for every iteration of the loop *)
      let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
			try
				let () = Unix.connect fd sockaddr in
				Unix.setsockopt fd Unix.TCP_NODELAY true;
				let ic = Unix.in_channel_of_descr fd in
				let oc = Unix.out_channel_of_descr fd in
				result := Some (ic, oc)
			with Unix.Unix_error(Unix.ECONNREFUSED, cmd, _) ->
        Unix.close fd;
				(* wait for the server to start *)
				Thread.delay 5.
			| e ->
        Unix.close fd;
        raise e
		done;
		match !result with
		| None -> assert false
		| Some x -> x

	let flush oc = ()
  end
  include IO

  module Ivar = struct
    type 'a t = {
      mutable v: 'a option;
      m: Mutex.t;
      c: Condition.t;
    }

    let create () = {
      v = None;
      m = Mutex.create ();
      c = Condition.create ();
    }

    let fill r x =
      with_lock r.m
        (fun () ->
          r.v <- Some x;
          Condition.signal r.c
        )

    let read r =
      with_lock r.m
        (fun () ->
          while r.v = None do
            Condition.wait r.c r.m
          done;
          match r.v with
          | Some x -> x
          | None -> assert false
        )
  end

  module Mutex = struct
    type t = Mutex.t

    let create = Mutex.create

    let with_lock = with_lock
  end

  module Clock = struct
    type timer = Protocol_unix_scheduler.t

    let started = ref false
    let started_m = Mutex.create ()

    let run_after timeout f =
      with_lock started_m
        (fun () ->
          if not !started then begin
            Protocol_unix_scheduler.start ();
            started := true
          end
        );
      Protocol_unix_scheduler.(one_shot (Delta timeout) "rpc" f)

    let cancel = Protocol_unix_scheduler.cancel
  end
end

let whoami = IO.whoami

module Connection = struct
  module C = Protocol.Connection(IO)

  let rpc t msg = match C.rpc t msg with
  | `Ok x -> Ok x
  | `Error y -> Error y

end

exception Timeout

module Opt = struct
	let iter f = function
	| None -> ()
	| Some x -> f x
	let map f = function
	| None -> None
	| Some x -> Some (f x)
end


let rpc_exn c frame = match Connection.rpc c frame with
	| Error e -> raise e
	| Ok raw -> raw

module Client = struct
	type t = {
		requests_conn: (IO.ic * IO.oc);
		events_conn: (IO.ic * IO.oc);
		requests_m: IO.Mutex.t;
		wakener: (Protocol.message_id, (Protocol.Message.t, exn) result IO.Ivar.t) Hashtbl.t;
		reply_queue_name: string;
	}

	let connect port =
		let token = IO.whoami () in
		let requests_conn = IO.connect port in
		let (_: string) = rpc_exn requests_conn (In.Login token) in
		let events_conn = IO.connect port in
		let (_: string) = rpc_exn events_conn (In.Login token) in

		let wakener = Hashtbl.create 10 in

		let reply_queue_name = rpc_exn requests_conn (In.CreateTransient token) in

		let requests_m = IO.Mutex.create () in
		let (_ : Thread.t) =
			let rec loop from =
				let timeout = 5. in
				let transfer = {
					In.from = from;
					timeout = timeout;
					queues = [ reply_queue_name ]
				} in
				let frame = In.Transfer transfer in
				let raw = rpc_exn events_conn frame in
				let transfer = Out.transfer_of_rpc (Jsonrpc.of_string raw) in
				match transfer.Out.messages with
				| [] -> loop from
				| m :: ms ->
					List.iter
						(fun (i, m) ->
							(* If the Ack doesn't belong to us then assume it's another thread *)
							IO.Mutex.with_lock requests_m (fun () ->
								match m.Message.kind with
								| Message.Response j ->
									if Hashtbl.mem wakener j then begin
										let (_: string) = rpc_exn events_conn (In.Ack i) in
										IO.Ivar.fill (Hashtbl.find wakener j) (Ok m);
									end else Printf.printf "no wakener for id %s,%Ld\n%!" (fst i) (snd i)
								| Message.Request _ -> ()
							)
						) transfer.Out.messages;
					loop (Some transfer.Out.next) in
			Thread.create loop None in
		{
			requests_conn = requests_conn;
			events_conn = events_conn;
			requests_m;
			wakener = wakener;
			reply_queue_name = reply_queue_name;
		}

	(* Maintain at most one connection per process *)
	let connect =
		let c = ref None in
		let m = Mutex.create () in
		fun port ->
			IO.Mutex.with_lock m (fun () ->
				match !c with
				| Some x -> x
				| None ->
					let c' = connect port in
					c := Some c';
					c'
			)

	let rpc c ?timeout ~dest:dest_queue_name x =
		let t = IO.Ivar.create () in
		let timer = Opt.map (fun timeout ->
      IO.Clock.run_after timeout (fun () -> IO.Ivar.fill t (Error Timeout))
		) timeout in

		let id = with_lock c.requests_m
		(fun () ->
			let (_: string) = rpc_exn c.requests_conn (In.CreatePersistent dest_queue_name) in
			let msg = In.Send(dest_queue_name, {
				Message.payload = x;
				kind = Message.Request c.reply_queue_name
			}) in
			let (id: string) = rpc_exn c.requests_conn msg in
			match message_id_opt_of_rpc (Jsonrpc.of_string id) with
			| None ->
				raise (Protocol.Queue_deleted dest_queue_name);
			| Some mid ->
				Hashtbl.add c.wakener mid t;
				mid
		) in
		(* now block waiting for our response *)
		match IO.Ivar.read t with
    | Ok response ->
      (* release resources *)
      Opt.iter IO.Clock.cancel timer;
      IO.Mutex.with_lock c.requests_m (fun () -> Hashtbl.remove c.wakener id);
      response.Message.payload
    | Error exn -> raise exn

	let list c prefix =
		IO.Mutex.with_lock c.requests_m
		(fun () ->
			let (result: string) = rpc_exn c.requests_conn (In.List prefix) in
			Out.string_list_of_rpc (Jsonrpc.of_string result)
		)
end

module Server = struct

	let listen process port name =
    let open IO.IO in
		let token = IO.whoami () in
		let request_conn = IO.connect port in
		let (_: string) = rpc_exn request_conn (In.Login token) in
		let reply_conn = IO.connect port in
		let (_: string) = rpc_exn reply_conn (In.Login token) in

		(* Only allow one reply RPC at a time (no pipelining) *)
		let m = IO.Mutex.create () in
		let reply req = IO.Mutex.with_lock m (fun () -> Connection.rpc reply_conn req) in

		Connection.rpc request_conn (In.Login token) >>= fun _ ->
		Connection.rpc request_conn (In.CreatePersistent name) >>= fun _ ->
		Printf.fprintf stdout "Serving requests forever\n%!";

		let rec loop from =
			let timeout = 5. in
			let transfer = {
				In.from = from;
				timeout = timeout;
				queues = [ name ];
			} in
			let frame = In.Transfer transfer in
			Connection.rpc request_conn frame >>= function
			| Error e ->
				Printf.fprintf stderr "Server.listen.loop: %s\n%!" (Printexc.to_string e);
				return ()
			| Ok raw ->
				let transfer = Out.transfer_of_rpc (Jsonrpc.of_string raw) in
				begin match transfer.Out.messages with
				| [] -> loop from
				| m :: ms ->
					List.iter
						(fun (i, m) ->
							let (_: Thread.t) = Thread.create
							(fun () ->
								let response =
									try
										process m.Message.payload
									with e ->
										Printexc.to_string e in
								response >>= fun response ->
								begin
									match m.Message.kind with
									| Message.Response _ ->
										(* response where a request should be: configuration error? *)
										return ()
									| Message.Request reply_to ->
										let request = In.Send(reply_to, { Message.kind = Message.Response i; payload = response }) in
										reply request >>= fun _ ->
										return ()
								end >>= fun () ->
								let request = In.Ack i in
								reply request >>= fun _ ->
								()
							) () in ()
						) transfer.Out.messages;
					loop (Some transfer.Out.next)
				end in
		loop None
end
