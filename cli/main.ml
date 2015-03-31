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
open Protocol_unix

let project_url = "http://github.com/djs55/message_switch"

open Cmdliner

module Common = struct
	type t = {
        verbose: bool;
        debug: bool;
        port: int;
	} with rpc

	let make verbose debug port =
		{ verbose; debug; port }

	let to_string x = Jsonrpc.to_string (rpc_of_t x)
end

let _common_options = "COMMON OPTIONS"

(* Options common to all commands *)
let common_options_t =
  let docs = _common_options in
  let debug =
    let doc = "Give only debug output." in
    Arg.(value & flag & info ["debug"] ~docs ~doc) in
  let verb =
    let doc = "Give verbose output." in
    let verbose = true, Arg.info ["v"; "verbose"] ~docs ~doc in
    Arg.(last & vflag_all [false] [verbose]) in
  let port =
    let doc = Printf.sprintf "Specify port to connect to the message switch." in
    Arg.(value & opt int 8080 & info ["port"] ~docs ~doc) in
  Term.(pure Common.make $ debug $ verb $ port)


(* Help sections common to all commands *)
let help = [
 `S _common_options;
 `P "These options are common to all commands.";
 `S "MORE HELP";
 `P "Use `$(mname) $(i,COMMAND) --help' for help on a single command."; `Noblank;
 `S "BUGS"; `P (Printf.sprintf "Check bug reports at %s" project_url);
]

(* Commands *)

let diagnostics common_opts =
  let c = IO.connect common_opts.Common.port in
  let _ = Connection.rpc c (In.Login (Protocol_unix.whoami ())) in
  match Connection.rpc c In.Diagnostics with
  | Error e -> `Error(true, Printexc.to_string e)
  | Ok raw ->
    let d = Diagnostics.t_of_rpc (Jsonrpc.of_string raw) in
    let open Protocol in
    let in_the_past = Int64.sub d.Diagnostics.current_time in
    let in_the_future x = Int64.sub x d.Diagnostics.current_time in
    let time f x =
      let ms = Int64.div (f x) 1_000_000L in
      Printf.sprintf "%Ld ms" ms in
    let origin = function
      | Anonymous id -> Printf.sprintf "anonymous-%s" id
      | Name x -> x in
    let kind = function
      | Message.Request q -> q
      | Message.Response _ -> "-" in
    let queue (name, queue) =
      Printf.printf "  %s next update expected: %s\n" name (match queue.Diagnostics.next_transfer_expected with None -> "None" | Some x -> time in_the_future x);
      List.iter
        (fun (id, entry) ->
          Printf.printf "    %Ld:  from: %s  age: %s\n" (snd id) (origin entry.Entry.origin) (time in_the_past entry.Entry.time);
          let message = entry.Entry.message in
          let payload = String.escaped message.Message.payload in
          let len = String.length payload in
          let max_len = 70 in
          Printf.printf "      %s\n" (if common_opts.Common.verbose || len < max_len then payload else String.sub payload 0 max_len);
          Printf.printf "        reply_to: %s\n" (kind message.Message.kind);
        ) queue.Diagnostics.queue_contents in
    Printf.printf "Switch uptime: %s\n" (time (fun x -> x) d.Diagnostics.current_time);
    print_endline "Permanent queues";
    if d.Diagnostics.permanent_queues = []
    then print_endline "  None"
    else List.iter queue d.Diagnostics.permanent_queues;
    print_endline "Transient queues";
    if d.Diagnostics.transient_queues = []
    then print_endline "  None"
    else List.iter queue d.Diagnostics.transient_queues;
    `Ok ()

let list common_opts prefix =
  let c = IO.connect common_opts.Common.port in
  let _ = Connection.rpc c (In.Login (Protocol_unix.whoami ())) in
  match Connection.rpc c (In.List prefix) with
  | Error e -> `Error(true, Printexc.to_string e)
  | Ok raw ->
    let all = Out.string_list_of_rpc (Jsonrpc.of_string raw) in
    List.iter print_endline all;
    `Ok ()

let ack common_opts name id = match name, id with
  | Some name, Some id ->
    let c = IO.connect common_opts.Common.port in
    let _ = Connection.rpc c (In.Login (Protocol_unix.whoami ())) in
    let _ = Connection.rpc c (In.Ack (name, id)) in
    `Ok ()
  | _, _ ->
    `Error(true, "Please supply both a queue name and message ID")

let destroy common_opts name = match name with
  | None ->
    `Error(true, "Please supply a queue name")
  | Some name ->
    let c = IO.connect common_opts.Common.port in
    let _ = Connection.rpc c (In.Login (Protocol_unix.whoami ())) in
    let _ = Connection.rpc c (In.Destroy name) in
    `Ok ()

module Opt = struct
  let iter f = function
    | None -> ()
    | Some x -> f x
end

let summarise_payload m =
  try
    let call = Jsonrpc.call_of_string m in
    call.Rpc.name
  with _ ->
    begin
      try
        let response = Jsonrpc.response_of_string m in
        if response.Rpc.success
        then "OK"
        else "FAILURE"
      with _ ->
        let limit = 10 in
        if String.length m > limit
        then String.sub m 0 limit
        else m
    end

let message ?(concise=false) = function
  | Event.Message (id, m) ->
    if concise
    then summarise_payload m.Message.payload
    else Printf.sprintf "%s.%Ld:%s" (fst id) (snd id) m.Message.payload
  | Event.Ack id -> Printf.sprintf "%s.%Ld:ack" (fst id) (snd id)

let mscgen common_opts =
  let c = IO.connect common_opts.Common.port in
  let trace = match Connection.rpc c (In.Trace(0L, 0.)) with
    | Error e -> raise e
    | Ok raw -> Out.trace_of_rpc (Jsonrpc.of_string raw) in
  let quote x = "\"" ^ x ^ "\""
 in
  let module StringSet = Set.Make(struct type t = string let compare = compare end) in
  let queues = List.fold_left (fun acc (_, event) -> StringSet.add event.Event.queue acc) StringSet.empty trace.Out.events in
  let inputs = List.fold_left (fun acc (_, event) -> match event.Event.input with
    | None -> acc
    | Some x -> StringSet.add x acc
  ) StringSet.empty trace.Out.events in
  let outputs = List.fold_left (fun acc (_, event) -> match event.Event.output with
    | None -> acc
    | Some x -> StringSet.add x acc
  ) StringSet.empty trace.Out.events in
  let print_event (_, e) =
    let body = String.escaped (message ~concise:true e.Event.message) in
    let to_arrow arrow queue connection =
      Printf.printf "%s %s %s [ label = \"%s\" ] ;\n" (quote connection) arrow (quote queue) body in
    let from_arrow arrow queue connection =
      Printf.printf "%s %s %s [ label = \"%s\" ] ;\n" (quote queue) arrow (quote connection) body in
    match e.Event.message with
    | Event.Message(_, { Message.kind = Message.Response _ }) ->
      (* Opt.iter (to_arrow "<<" e.Event.queue) e.Event.output; *)
      Opt.iter (from_arrow "<<" e.Event.queue) e.Event.input
    | Event.Message(_, { Message.kind = Message.Request _ }) ->
      Opt.iter (from_arrow "=>" e.Event.queue) e.Event.output;
      Opt.iter (to_arrow "=>" e.Event.queue) e.Event.input;
    | Event.Ack _ -> () in
  Printf.printf "msc {\n";
  Printf.printf "%s;\n" (String.concat "," (List.map quote (StringSet.((elements (union(union inputs outputs) queues))))));
  List.iter print_event trace.Out.events;
  Printf.printf "}\n";
  `Ok ()

let tail common_opts follow =
  let c = IO.connect common_opts.Common.port in
  let from = ref 0L in
  let timeout = 5. in
  let start = ref None in
  let widths = [ Some 5; Some 15; Some 4; Some 30; Some 4; Some 15; Some 5; None ] in
  let print_row row =
    List.iter (fun (txt, size) ->
      let txt = match size with
      | None -> txt
      | Some size ->
      let txt' = String.length txt in
      if txt' > size then String.sub txt (txt'-size) size else txt ^ (String.make (size - txt') ' ') in
      print_string txt;
      print_string " "
    ) (List.combine row widths);
    print_endline "" in
  let finished = ref false in
  while not(!finished) do
    match Connection.rpc c (In.Trace (!from, timeout)) with
      | Error e -> raise e
      | Ok raw ->
        let trace = Out.trace_of_rpc (Jsonrpc.of_string raw) in
        let endpoint = function
          | None -> "-"
          | Some x -> x in
        let relative_time event = match !start with
          | None ->
            start := Some event.Event.time;
            0.
          | Some t ->
            event.Event.time -. t in
	let secs = function
          | None -> ""
          | Some x -> Printf.sprintf "%.1f" (Int64.(to_float (div x 1_000_000_000L)) /. 1000.) in
        let rows = List.map (fun (id, event) ->
          let time = relative_time event in
          let m = event.Event.message in
          [ Printf.sprintf "%.1f" time ] @ (match m with
            | Event.Message(_, { Message.kind = Message.Response _ }) ->
              [ endpoint event.Event.output; "<-"; event.Event.queue; "<-"; endpoint event.Event.input ]
            | Event.Message(_, { Message.kind = Message.Request _ }) ->
              [ endpoint event.Event.input; "->"; event.Event.queue; "->"; endpoint event.Event.output ]
            | Event.Ack id ->
              [ endpoint event.Event.input; "->"; event.Event.queue; ""; "" ]
          ) @ [ secs event.Event.processing_time; message m ]
        ) trace.Out.events in
        List.iter print_row rows;
        flush stdout;
        finished := not follow;
        from :=
          begin match trace.Out.events with
            | [] -> !from
            | (id, _) :: ms -> Int64.add 1L (List.fold_left max id (List.map fst ms))
          end;
    done;
    `Ok ()

let diagnostics_cmd =
  let doc = "dump the current switch state" in
  let man = [
    `S "DESCRIPTION";
    `P "Dumps the current switch state for diagnostic purposes.";
  ] @ help in
  Term.(ret(pure diagnostics $ common_options_t)),
  Term.info "diagnostics" ~sdocs:_common_options ~doc ~man

let list_cmd =
  let doc = "list the currently-known queues" in
  let man = [
    `S "DESCRIPTION";
    `P "Print a list of all queues registered with the message switch";
  ] @ help in
  let prefix =
    let doc = Printf.sprintf "List queues with a specific prefix." in
    Arg.(value & opt string "" & info ["prefix"] ~docv:"PREFIX" ~doc) in
  Term.(ret(pure list $ common_options_t $ prefix)),
  Term.info "list" ~sdocs:_common_options ~doc ~man

let tail_cmd =
  let doc = "display the most recent trace events" in
  let man = [
    `S "DESCRIPTION";
    `P "Display the most recent trace events captured within the message switch. Similar to the shell command 'tail'";
  ] @ help in
  let follow =
    let doc = "keep waiting for new events to display." in
    Arg.(value & flag & info ["follow"] ~docv:"FOLLOW" ~doc) in
  Term.(ret(pure tail $ common_options_t $ follow)),
  Term.info "tail" ~sdocs:_common_options ~doc ~man

let mscgen_cmd =
  let doc = "display the most recent trace events in mscgen input format" in
  let man = [
    `S "DESCRIPTION";
    `P "Display the most recent trace events in mscgen input format, allowing message sequence charts to be rendered";
  ] @ help in
  Term.(ret(pure mscgen $ common_options_t)),
  Term.info "mscgen" ~sdocs:_common_options ~doc ~man

let ack_cmd =
  let doc = "acknowledge processing of a specific message" in
  let man = [
    `S "DESCRIPTION";
    `P "Acknowledge processing of a specific message and remove it from any queue.";
  ] @ help in
  let qname =
    let doc = "queue name" in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"QUEUE" ~doc) in
  let id =
    let doc = "message id" in
    Arg.(value & pos 1 (some int64) None & info [] ~docv:"ACK" ~doc) in
  Term.(ret(pure ack $ common_options_t $ qname $ id)),
  Term.info "ack" ~sdocs:_common_options ~doc ~man

let destroy_cmd =
  let doc = "destroy a named queue" in
  let man = [
    `S "DESCRIPTION";
    `P "Destroy a whole named queue, including all the messages queued inside.";
  ] @ help in
  let n =
    let doc = "queue name" in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"QUEUE" ~doc) in
  Term.(ret(pure destroy $ common_options_t $ n)),
  Term.info "destroy" ~sdocs:_common_options ~doc ~man

let string_of_ic ?end_marker ic =
  let lines = ref [] in
  try
    while true do
      let line = input_line ic in
      (match end_marker with None -> () | Some x -> if x = line then raise End_of_file);
      lines := line :: !lines
    done;
    ""
  with End_of_file -> String.concat "\n" (List.rev !lines)

let call common_options_t name body path timeout =
  match name with
  | None -> `Error(true, "a queue name is required")
  | Some name ->
    begin
    let txt = match body, path with
    | None, None ->
      Printf.printf "Enter body text:\n%!";
      string_of_ic stdin
    | Some _, Some _ ->
      failwith "please supply either a body or a file, not both"
    | Some x, _ -> x
    | None, Some x ->
      let ic = open_in x in
      let txt = string_of_ic ic in
      close_in ic;
      txt in

    let c = Client.connect common_options_t.Common.port in
    let result = Client.rpc c ?timeout ~dest:name txt in
    print_endline result;
    `Ok ()
    end

let call_cmd =
  let doc = "perform a remote procedure call" in
  let man = [
    `S "DESCRIPTION";
    `P "Perform a remote procedure call against a named service.";
  ] @ help in
  let qname =
    let doc = "Name of remote service to invoke." in
    Arg.(value & pos 0 (some string) None & info [] ~doc) in
  let body =
    let doc = "Request text to send to the remote service." in
    Arg.(value & opt (some string) None & info ["body"] ~docv:"BODY" ~doc) in
  let path =
    let doc = "File containing request text to send to the remote service." in
    Arg.(value & opt (some file) None & info ["file"] ~docv:"FILE" ~doc) in
  let timeout =
    let doc = "Time to wait for a response before failing." in
    Arg.(value & opt (some int) None & info ["timeout"] ~docv:"TIMEOUT" ~doc) in

  Term.(ret(pure call $ common_options_t $ qname $ body $ path $ timeout)),
  Term.info "call" ~sdocs:_common_options ~doc ~man

let serve common_options_t name program =
  match name with
  | None ->
    `Error(true, "a queue name is required")
  | Some name ->
    Protocol_unix.Server.listen (fun req ->
      match program with
      | None ->
        print_endline "Received:";
        print_endline req;
        print_endline "Enter body text: (end with a \".\")";
        string_of_ic ~end_marker:"." stdin
      | Some program ->
        let stdout, stdin, stderr = Unix.open_process_full program [| program |] in
        output_string stdin req; close_out stdin;
        let res = string_of_ic stdout in
        let (_: Unix.process_status) = Unix.close_process_full (stdout, stdin, stderr) in
        res
    ) common_options_t.Common.port name;
    `Ok ()

let serve_cmd =
  let doc = "respond to remote procedure calls" in
  let man = [
    `S "DESCRIPTION";
    `P "Listen for remote procedure calls and run the specified program with the body, returning the program's output as the response.";
  ] @ help in
  let qname =
    let doc = "Name of service to implement." in
    Arg.(value & pos 0 (some string) None & info [] ~doc) in
  let program =
    let doc = "Path of the program to invoke on every call." in
    Arg.(value & opt (some file) None & info ["program"] ~doc) in

  Term.(ret(pure serve $ common_options_t $ qname $ program)),
  Term.info "serve" ~sdocs:_common_options ~doc ~man

let default_cmd =
  let doc = "interact with an XCP message switch" in
  let man = help in
  Term.(ret (pure (fun _ -> `Help (`Pager, None)) $ common_options_t)),
  Term.info "m-cli" ~version:"1.0.0" ~sdocs:_common_options ~doc ~man

let cmds = [list_cmd; tail_cmd; mscgen_cmd; ack_cmd; destroy_cmd; call_cmd; serve_cmd; diagnostics_cmd]

let _ =
  match Term.eval_choice default_cmd cmds with
  | `Error _ -> exit 1
  | _ -> exit 0
