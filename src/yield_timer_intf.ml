open! Core
open! Async_kernel

(** A [Yield_timer.t] provides an easy way to periodically call a [yield] function within
    some iterator. The main use case for this is for functions that perform long
    synchronous tasks to behave nicely with async. For example, one might want to yield
    every few seconds to give heartbeat threads a chance to run. *)

module type S = sig
  module Monad : Monad.S

  type t

  val create
    :  ?time_source:[> read ] Time_source.T1.t
         (** defaults to [Time_source.wall_clock ()] *)
    -> ?yield:(unit -> unit Monad.t) (** defaults to [Scheduler.yield] *)
    -> yield_every:Time_ns.Span.t
    -> unit
    -> t

  (** [yield_if_its_time t] yields if it's been at least [t.yield_every] since the last
      time [t.yield] function was called. It is similar to the closure provided by
      [Async.Scheduler.yield_every]. *)
  val yield_if_its_time : t -> unit Monad.t

  (** [repeat_until_finished t init f] is like [Deferred.repeat_until_finished], except it
      calls [t.yield] if it's been at least [t.yield_every] since the last time [t.yield]
      function was called. *)
  val repeat_until_finished
    :  t
    -> 'state
    -> ('state -> [ `Finished of 'result | `Repeat of 'state ] Monad.t)
    -> 'result Monad.t

  val repeat_until_finished'
    :  t
    -> 'state
    -> ('state -> [ `Finished of 'result | `Repeat of 'state ])
    -> 'result Monad.t

  (** Convenience functions for iterating over a sequence. This intends to make the
      functions above easier to use for users that already have a container that's
      convertible to a sequence, e.g. a map:

      {[
        let iter_map_while_behaving_nicely_with_async map ~yield_timer ~f =
          Yield_timer.Sequence.fold'
            yield_timer
            (Map.to_sequence map)
            ~init:()
            ~f:(fun () (key, data) -> f ~key ~data)
        ;;
      ]} *)
  module Sequence : sig
    val fold
      :  t
      -> 'a Sequence.t
      -> init:'accum
      -> f:('accum -> 'a -> 'accum Monad.t)
      -> 'accum Monad.t

    val fold'
      :  t
      -> 'a Sequence.t
      -> init:'accum
      -> f:('accum -> 'a -> 'accum)
      -> 'accum Monad.t

    (** Returns [true] if and only if there exists an element for which the provided
        function evaluates to [true]. This is a short-circuiting operation. *)
    val exists : t -> 'a Sequence.t -> f:('a -> bool Monad.t) -> bool Monad.t

    val exists' : t -> 'a Sequence.t -> f:('a -> bool) -> bool Monad.t
    val iter : t -> 'a Sequence.t -> f:('a -> unit Monad.t) -> unit Monad.t
    val iter' : t -> 'a Sequence.t -> f:('a -> unit) -> unit Monad.t

    (** The resulting sequence is *not* produced incrementally: we scan the entire input
        sequence first, then return the output sequence. *)
    val map : t -> 'a Sequence.t -> f:('a -> 'b Monad.t) -> 'b Sequence.t Monad.t

    val map' : t -> 'a Sequence.t -> f:('a -> 'b) -> 'b Sequence.t Monad.t
    val filter : t -> 'a Sequence.t -> f:('a -> bool Monad.t) -> 'a Sequence.t Monad.t
    val filter' : t -> 'a Sequence.t -> f:('a -> bool) -> 'a Sequence.t Monad.t

    val filter_map
      :  t
      -> 'a Sequence.t
      -> f:('a -> 'b option Monad.t)
      -> 'b Sequence.t Monad.t

    val filter_map' : t -> 'a Sequence.t -> f:('a -> 'b option) -> 'b Sequence.t Monad.t
  end

  module Map : sig
    val filter
      :  t
      -> ('k, 'v, 'cmp) Map.t
      -> f:('v -> bool Monad.t)
      -> ('k, 'v, 'cmp) Map.t Monad.t

    val filter'
      :  t
      -> ('k, 'v, 'cmp) Map.t
      -> f:('v -> bool)
      -> ('k, 'v, 'cmp) Map.t Monad.t

    val filteri
      :  t
      -> ('k, 'v, 'cmp) Map.t
      -> f:(key:'k -> data:'v -> bool Monad.t)
      -> ('k, 'v, 'cmp) Map.t Monad.t

    val filteri'
      :  t
      -> ('k, 'v, 'cmp) Map.t
      -> f:(key:'k -> data:'v -> bool)
      -> ('k, 'v, 'cmp) Map.t Monad.t

    val filter_map
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:('v1 -> 'v2 option Monad.t)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val filter_map'
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:('v1 -> 'v2 option)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val filter_mapi
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:(key:'k -> data:'v1 -> 'v2 option Monad.t)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val filter_mapi'
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:(key:'k -> data:'v1 -> 'v2 option)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val map
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:('v1 -> 'v2 Monad.t)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val map'
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:('v1 -> 'v2)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val mapi
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:(key:'k -> data:'v1 -> 'v2 Monad.t)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val mapi'
      :  t
      -> ('k, 'v1, 'cmp) Map.t
      -> f:(key:'k -> data:'v1 -> 'v2)
      -> ('k, 'v2, 'cmp) Map.t Monad.t

    val fold
      :  t
      -> ('k, 'v, 'cmp) Map_intf.Map.t
      -> init:'accum
      -> f:(key:'k -> data:'v -> 'accum -> 'accum Monad.t)
      -> 'accum Monad.t

    val fold'
      :  t
      -> ('k, 'v, 'cmp) Map_intf.Map.t
      -> init:'accum
      -> f:(key:'k -> data:'v -> 'accum -> 'accum)
      -> 'accum Monad.t

    val iter
      :  t
      -> ('k, 'v, 'cmp) Map_intf.Map.t
      -> f:(key:'k -> data:'v -> unit Monad.t)
      -> unit Monad.t

    val iter'
      :  t
      -> ('k, 'v, 'cmp) Map_intf.Map.t
      -> f:(key:'k -> data:'v -> unit)
      -> unit Monad.t

    val merge
      :  t
      -> how:[ `Sequential ]
      -> ('k, 'v1, 'cmp) Map_intf.Map.t
      -> ('k, 'v2, 'cmp) Map_intf.Map.t
      -> f:(key:'k -> ('v1, 'v2) Map.Merge_element.t -> 'v3 option Monad.t)
      -> ('k, 'v3, 'cmp) Map_intf.Map.t Monad.t

    val merge'
      :  t
      -> how:[ `Sequential ]
      -> ('k, 'v1, 'cmp) Map_intf.Map.t
      -> ('k, 'v2, 'cmp) Map_intf.Map.t
      -> f:(key:'k -> ('v1, 'v2) Map.Merge_element.t -> 'v3 option)
      -> ('k, 'v3, 'cmp) Map_intf.Map.t Monad.t

    (** [merge_sequenced] merges two maps into a sequence. It returns the sequence in
        constant time and doesn't use a yield timer. It's a building block for [merge],
        but is also useful on its own.

        It lives here rather than in [Base]/[Core] since it's a composition of existing
        [Base] functions. It was considered too specific to add there. *)
    val merge_sequenced
      :  ?order:[ `Increasing_key | `Decreasing_key ]
      -> ('k, 'v1, 'cmp) Map_intf.Map.t
      -> ('k, 'v2, 'cmp) Map_intf.Map.t
      -> ('k * ('v1, 'v2) Map.Merge_element.t) Core.Sequence.t

    val transpose_keys
      :  t
      -> ('a, 'b) Comparator.Module.t
      -> ('c, ('a, 'd, 'e) Map.t, 'f) Map.t
      -> ('a, ('c, 'd, 'f) Map.t, 'b) Map.t Monad.t

    val of_list_with_key_or_error
      :  t
      -> ('k, 'cmp) Comparator.Module.t
      -> 'v list
      -> get_key:('v -> 'k)
      -> ('k, 'v, 'cmp) Map.t Or_error.t Monad.t
  end

  module Set : sig
    val fold
      :  t
      -> ('v, 'cmp) Set_intf.Set.t
      -> init:'accum
      -> f:('accum -> 'v -> 'accum Monad.t)
      -> 'accum Monad.t

    val fold'
      :  t
      -> ('v, 'cmp) Set_intf.Set.t
      -> init:'accum
      -> f:('accum -> 'v -> 'accum)
      -> 'accum Monad.t

    val iter : t -> ('v, 'cmp) Set_intf.Set.t -> f:('v -> unit Monad.t) -> unit Monad.t
    val iter' : t -> ('v, 'cmp) Set_intf.Set.t -> f:('v -> unit) -> unit Monad.t

    val filter
      :  t
      -> ('v, 'cmp) Set_intf.Set.t
      -> f:('v -> bool Monad.t)
      -> ('v, 'cmp) Set_intf.Set.t Monad.t

    val filter'
      :  t
      -> ('v, 'cmp) Set_intf.Set.t
      -> f:('v -> bool)
      -> ('v, 'cmp) Set_intf.Set.t Monad.t
  end

  module List : sig
    val fold
      :  t
      -> 'v list
      -> init:'accum
      -> f:('accum -> 'v -> 'accum Monad.t)
      -> 'accum Monad.t

    val fold'
      :  t
      -> 'v list
      -> init:'accum
      -> f:('accum -> 'v -> 'accum)
      -> 'accum Monad.t

    val iter : t -> 'v list -> f:('v -> unit Monad.t) -> unit Monad.t
    val iter' : t -> 'v list -> f:('v -> unit) -> unit Monad.t

    val filter
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> bool Monad.t)
      -> 'a list Monad.t

    val filter' : t -> 'a list -> how:[ `Sequential ] -> f:('a -> bool) -> 'a list Monad.t

    val filter_map
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> 'b option Monad.t)
      -> 'b list Monad.t

    val filter_map'
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> 'b option)
      -> 'b list Monad.t

    val map
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> 'b Monad.t)
      -> 'b list Monad.t

    val map' : t -> 'a list -> how:[ `Sequential ] -> f:('a -> 'b) -> 'b list Monad.t

    val concat_map
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> 'b list Monad.t)
      -> 'b list Monad.t

    val concat_map'
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> 'b list)
      -> 'b list Monad.t

    val partition_map
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> ('b, 'c) Either.t Monad.t)
      -> ('b list * 'c list) Monad.t

    val partition_map'
      :  t
      -> 'a list
      -> how:[ `Sequential ]
      -> f:('a -> ('b, 'c) Either.t)
      -> ('b list * 'c list) Monad.t

    (** [max_elt] and [min_elt] follow the same semantics as the corresponding [Core.List]
        function. *)

    val max_elt : t -> 'a list -> compare:('a -> 'a -> int) -> 'a option Monad.t
    val min_elt : t -> 'a list -> compare:('a -> 'a -> int) -> 'a option Monad.t
  end
end

module type S_deferred = sig
  include S

  module Pipe : sig
    val iter_without_pushback : t -> 'a Pipe.Reader.t -> f:('a -> unit) -> unit Deferred.t

    val fold_without_pushback
      :  t
      -> 'a Pipe.Reader.t
      -> init:'accum
      -> f:('accum -> 'a -> 'accum)
      -> 'accum Deferred.t
  end

  module Pipe_with_writer_error : sig
    val iter_without_pushback
      :  t
      -> ('a, 'error) Pipe_with_writer_error.t
      -> f:('a -> unit)
      -> (unit, 'error) Deferred.Result.t

    val fold_without_pushback
      :  t
      -> ('a, 'error) Pipe_with_writer_error.t
      -> init:'accum
      -> f:('accum -> 'a -> 'accum)
      -> ('accum, 'error) Deferred.Result.t
  end
end

module type Yield_timer = sig
  module type S = S

  include S_deferred with type 'a Monad.t = 'a Deferred.t

  (** Sometimes, libraries which are otherwise entirely non-async may want to use yield
      timers in order to help clients avoid long-async cycles. However, some clients may
      prefer the non-async version. If these libraries are functorized on yield timer,
      clients can then use this version of yield timer to maintain the previous, non-async
      behavior. *)
  module Without_yields : sig
    include S with type 'a Monad.t = 'a

    val without_yields : t
  end
end
