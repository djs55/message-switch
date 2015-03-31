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

exception Queue_deleted of string

type message_id = string * int64
(** uniquely identifier for this message *)

val rpc_of_message_id: message_id -> Rpc.t
val message_id_of_rpc: Rpc.t -> message_id

val rpc_of_message_id_opt: message_id option -> Rpc.t
val message_id_opt_of_rpc: Rpc.t -> message_id option

module Message : sig
	type kind =
	| Request of string
	| Response of message_id
	type t = {
		payload: string; (* switch to Rpc.t *)
		kind: kind;
	}
	val t_of_rpc: Rpc.t -> t
	val rpc_of_t: t -> Rpc.t
end

module Event : sig
	type message =
		| Message of message_id * Message.t
		| Ack of message_id

	type t = {
		time: float;
		input: string option;
		queue: string;
		output: string option;
		message: message;
		processing_time: int64 option;
	}
	val t_of_rpc: Rpc.t -> t
	val rpc_of_t: t -> Rpc.t
end

module In : sig
	type transfer = {
		from: string option;
		timeout: float;
		queues: string list;
	}

	type t =
	| Login of string            (** Associate this transport-level channel with a session *)
	| CreatePersistent of string (** Create a persistent named queue *)
	| CreateTransient of string  (** Create a transient named queue which will be deleted when the client disconnects *)
	| Destroy of string          (** Destroy a named queue *)
	| Send of string * Message.t (** Send a message to a queue *)
	| Transfer of transfer       (** blocking wait for new messages *)
	| Trace of int64 * float     (** blocking wait for trace data *)
	| Ack of message_id          (** ACK this particular message *)
	| List of string             (** return a list of queue names with a prefix *)
	| Diagnostics                (** return a diagnostic dump *)
	| Get of string list         (** return a web interface resource *)

	val rpc_of_t : t -> Rpc.t
	val t_of_rpc : Rpc.t -> t

	val headers: string -> Cohttp.Header.t

	val of_request: string -> Cohttp.Code.meth -> string -> t option
	(** parse a [t] from an HTTP request and body  *)

	val to_request: t -> (string option) * Cohttp.Code.meth * Uri.t
	(** print a [t] to an HTTP request and body *)
end

type origin =
	| Anonymous of string (** An un-named connection, probably a temporary client connection *)
	| Name of string   (** A service with a well-known name *)
(** identifies where a message came from *)

module Entry : sig
	type t = {
		origin: origin;
		time: int64; (** ns *)
		message: Message.t;
	}
	(** an enqueued message *)

	val make: int64 -> origin -> Message.t -> t
end

module Diagnostics : sig
	type queue_contents = (message_id * Entry.t) list

	type queue = {
		next_transfer_expected: int64 option;
		queue_contents: queue_contents;
	}

	type t = {
		current_time: int64;
		permanent_queues: (string * queue) list;
		transient_queues: (string * queue) list;
	}
	val rpc_of_t: t -> Rpc.t
	val t_of_rpc: Rpc.t -> t
end


module Out : sig
	type transfer = {
		messages: (message_id * Message.t) list;
		next: string;
	}
	val transfer_of_rpc: Rpc.t -> transfer
	val rpc_of_transfer: transfer -> Rpc.t

	type trace = {
		events: (int64 * Event.t) list;
	}
	val trace_of_rpc: Rpc.t -> trace
	val rpc_of_trace: trace -> Rpc.t

	val string_list_of_rpc: Rpc.t -> string list
	val rpc_of_string_list: string list -> Rpc.t

	type t =
	| Login
	| Create of string
	| Destroy
	| Send of message_id option
	| Transfer of transfer
	| Trace of trace
	| Ack
	| List of string list
	| Diagnostics of Diagnostics.t
	| Not_logged_in
	| Get of string

	val to_response : t -> Cohttp.Code.status_code * string
end

type ('a, 'b) result =
| Ok of 'a
| Error of 'b

exception Failed_to_read_response

exception Unsuccessful_response

exception Timeout

module type S = sig
  val whoami: unit -> string

  module IO: sig
    include Cohttp.S.IO

    val map: ('a -> 'b) -> 'a t -> 'b t

    val any: 'a t list -> 'a t

    val is_determined: 'a t -> bool
  end

  val connect: int -> (IO.ic * IO.oc) IO.t

  val disconnect: (IO.ic * IO.oc) -> unit IO.t

  module Ivar : sig
    type 'a t

    val create: unit -> 'a t

    val fill: 'a t -> 'a -> unit

    val read: 'a t -> 'a IO.t
  end

  module Mutex : sig
    type t

    val create: unit -> t

    val with_lock: t -> (unit -> 'a IO.t) -> 'a IO.t
  end

  module Clock : sig
    type timer

    val run_after: int -> (unit-> unit) -> timer

    val cancel: timer -> unit
  end
end

module Connection(IO: Cohttp.S.IO) : sig
	val rpc: (IO.ic * IO.oc) -> In.t -> [ `Ok of string | `Error of exn] IO.t
end

module Server(M: S) : sig
  type t
  (** A listening server *)

	val listen: (string -> string M.IO.t) -> (M.IO.ic * M.IO.oc) -> string -> t M.IO.t

  val shutdown: t -> unit M.IO.t
  (** [shutdown t] shutdown a server *)
end

module Client(M: S) : sig
  type t

  val connect: int -> string -> [ `Ok of t | `Error of exn ] M.IO.t

  val disconnect: t -> unit M.IO.t
  (** [disconnect] closes the connection *)

  val rpc: t -> ?timeout: int -> string  -> [ `Ok of string | `Error of exn ] M.IO.t

  val list: t -> string -> [ `Ok of string list | `Error of exn ] M.IO.t

  val destroy: t -> string -> [ `Ok of unit | `Error of exn ] M.IO.t
  (** [destroy t queue_name] destroys the named queue, and all associated
      messages. *)
end
