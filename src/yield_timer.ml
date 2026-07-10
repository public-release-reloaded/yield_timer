open! Core
open! Async_kernel

module Make (Monad : sig
    include Monad.S

    val default_yield : unit -> unit t

    val repeat_until_finished
      :  'state
      -> ('state -> [ `Repeat of 'state | `Finished of 'result ] t)
      -> 'result t
  end) =
struct
  module Monad = Monad
  open Monad.Let_syntax

  type t =
    { time_source : Time_source.t
    ; yield : unit -> unit Monad.t
    ; yield_every : Time_ns.Span.t
    ; mutable next_yield_time : Time_ns.t
    }

  let create ?time_source ?(yield = Monad.default_yield) ~yield_every () =
    let time_source =
      Option.map time_source ~f:Time_source.read_only
      |> Option.value_or_thunk ~default:Time_source.wall_clock
    in
    { time_source
    ; yield
    ; yield_every
    ; next_yield_time = Time_ns.add (Time_source.now time_source) yield_every
    }
  ;;

  let should_yield t = Time_ns.(Time_source.now t.time_source >= t.next_yield_time)

  let yield_if_its_time t =
    if not (should_yield t)
    then Monad.return ()
    else (
      let%map () = t.yield () in
      t.next_yield_time <- Time_ns.add (Time_source.now t.time_source) t.yield_every)
  ;;

  module Iterators = struct
    let repeat_until_finished t init f =
      Monad.repeat_until_finished init (fun state ->
        let%bind () = yield_if_its_time t in
        f state)
    ;;

    let repeat_until_finished' t init f =
      Monad.repeat_until_finished init (fun state ->
        let%map () = yield_if_its_time t in
        f state)
    ;;

    module Sequence = struct
      let fold t seq ~init ~f =
        repeat_until_finished t (seq, init) (fun (seq, accum) ->
          match Sequence.next seq with
          | None -> return (`Finished accum)
          | Some (next, seq) ->
            let%map accum = f accum next in
            `Repeat (seq, accum))
      ;;

      (* It's intentional that this is implemented in terms of [fold] rather than
         explicitly. The extra bind here doesn't have much performance cost because we're
         using [Eager_deferred] *)
      let fold' t seq ~init ~f =
        fold t seq ~init ~f:(fun accum next -> return (f accum next))
      ;;

      let exists t seq ~f =
        repeat_until_finished t seq (fun seq ->
          match Sequence.next seq with
          | None -> return (`Finished false)
          | Some (next, seq) ->
            (match%map f next with
             | true -> `Finished true
             | false -> `Repeat seq))
      ;;

      let exists' t seq ~f = exists t seq ~f:(fun next -> return (f next))
      let iter t seq ~f = fold t seq ~init:() ~f:(fun () next -> f next)
      let iter' t seq ~f = fold' t seq ~init:() ~f:(fun () next -> f next)

      let filter t seq ~f =
        let%map reversed_list =
          fold t seq ~init:[] ~f:(fun accum value ->
            match%map f value with
            | true -> value :: accum
            | false -> accum)
        in
        Sequence.of_list (List.rev reversed_list)
      ;;

      let filter' t seq ~f = filter t seq ~f:(fun value -> return (f value))

      let filter_map t seq ~f =
        let%map reversed_list =
          fold t seq ~init:[] ~f:(fun accum value ->
            match%map f value with
            | Some value' -> value' :: accum
            | None -> accum)
        in
        Sequence.of_list (List.rev reversed_list)
      ;;

      let filter_map' t seq ~f = filter_map t seq ~f:(fun value -> return (f value))

      let map t seq ~f =
        filter_map t seq ~f:(fun value -> Monad.map (f value) ~f:Option.return)
      ;;

      let map' t seq ~f = map t seq ~f:(fun value -> return (f value))
    end

    module Map = struct
      let fold_internal sequence_fold t map ~init ~f =
        let sequence = Map.to_sequence map in
        sequence_fold t sequence ~init ~f:(fun acc (key, data) -> f ~key ~data acc)
      ;;

      let fold t = fold_internal Sequence.fold t
      let fold' t = fold_internal Sequence.fold' t

      let filteri t map ~f =
        fold
          t
          map
          ~init:(Map.empty (Map.comparator_s map))
          ~f:(fun ~key ~data accum ->
            match%map f ~key ~data with
            | true -> Map.add_exn accum ~key ~data
            | false -> accum)
      ;;

      let filteri' t map ~f = filteri t map ~f:(fun ~key ~data -> return (f ~key ~data))
      let filter t map ~f = filteri t map ~f:(fun ~key:_ ~data -> f data)
      let filter' t map ~f = filter t map ~f:(fun data -> return (f data))

      let filter_mapi t map ~f =
        fold
          t
          map
          ~init:(Map.empty (Map.comparator_s map))
          ~f:(fun ~key ~data accum ->
            match%map f ~key ~data with
            | Some data' -> Map.add_exn accum ~key ~data:data'
            | None -> accum)
      ;;

      let filter_mapi' t map ~f =
        filter_mapi t map ~f:(fun ~key ~data -> return (f ~key ~data))
      ;;

      let filter_map t map ~f = filter_mapi t map ~f:(fun ~key:_ ~data -> f data)
      let filter_map' t map ~f = filter_map t map ~f:(fun data -> return (f data))
      let map t map ~f = filter_mapi t map ~f:(fun ~key:_ ~data -> f data >>| Option.some)
      let map' t map_ ~f = map t map_ ~f:(fun data -> return (f data))

      let mapi t map ~f =
        filter_mapi t map ~f:(fun ~key ~data -> f ~key ~data >>| Option.some)
      ;;

      let mapi' t map ~f = mapi t map ~f:(fun ~key ~data -> return (f ~key ~data))
      let iter t map ~f = fold t map ~f:(fun ~key ~data () -> f ~key ~data) ~init:()
      let iter' t map ~f = fold' t map ~f:(fun ~key ~data () -> f ~key ~data) ~init:()

      let merge_sequenced ?(order = `Increasing_key) map1 map2 =
        let seq1 = Map.to_sequence ~order map1 in
        let seq2 = Map.to_sequence ~order map2 in
        let compare =
          let compare = Comparator.compare (Map.comparator map1) in
          match order with
          | `Increasing_key -> compare
          | `Decreasing_key -> Comparable.compare_reversed compare
        in
        Core.Sequence.merge_with_duplicates seq1 seq2 ~compare:(fun (key1, _) (key2, _) ->
          compare key1 key2)
        |> Core.Sequence.map ~f:(function
          | Left (key, l) -> key, `Left l
          | Right (key, r) -> key, `Right r
          | Both ((key, l), (_, r)) -> key, `Both (l, r))
      ;;

      let merge t ~how:`Sequential map1 map2 ~f =
        let empty_map = Map.empty (Map.comparator_s map1) in
        merge_sequenced map1 map2
        |> Sequence.fold t ~init:empty_map ~f:(fun acc (key, merge_element) ->
          match%map f ~key merge_element with
          | None -> acc
          | Some data -> Map.add_exn acc ~key ~data)
      ;;

      (* As in [Sequence.fold'] above, we don't reimplement this explicitly. *)
      let merge' t ~how map1 map2 ~f =
        merge t ~how map1 map2 ~f:(fun ~key merge_element ->
          return (f ~key merge_element))
      ;;

      let transpose_keys t (m : _ Comparator.Module.t) map =
        (* Yield_timer.Map.transpose_keys uses Yield_timer.Map.fold' so there are no tests
           of correct yielding, only correct output. *)
        let singleton = Map.singleton (Map.comparator_s map) in
        fold
          t
          ~init:(Map.empty m)
          map
          ~f:(fun ~key:old_external_key ~data:internal_map init ->
            fold' t ~init internal_map ~f:(fun ~key:old_internal_key ~data map ->
              Map.update map old_internal_key ~f:(function
                | None -> singleton old_external_key data
                | Some map -> Map.set map ~key:old_external_key ~data)))
      ;;

      let of_list_with_key t list ~get_key ~comparator =
        let sequence = Core.Sequence.of_list list in
        repeat_until_finished
          t
          (sequence, Map.Tree.empty ~comparator)
          (fun (seq, tree) ->
            match Core.Sequence.next seq with
            | None -> return (`Finished (`Ok tree))
            | Some (data, seq) ->
              let key = get_key data in
              let acc = Map.Tree.set ~key ~data tree ~comparator in
              if Map.Tree.length tree = Map.Tree.length acc
              then return (`Finished (`Duplicate_key key))
              else return (`Repeat (seq, acc)))
      ;;

      let of_list_with_key_or_error t (m : _ Comparator.Module.t) list ~get_key =
        let comparator = Comparator.of_module m in
        match%map.Monad of_list_with_key t list ~get_key ~comparator with
        | `Ok tree -> Ok (Map.Using_comparator.of_tree ~comparator tree)
        | `Duplicate_key key ->
          Or_error.error
            "Map.of_list_with_key_or_error: duplicate key"
            key
            (Comparator.sexp_of_t comparator)
      ;;
    end

    module Set = struct
      let fold_internal sequence_fold yield_timer set ~init ~f =
        let sequence = Set.to_sequence set in
        sequence_fold yield_timer sequence ~init ~f
      ;;

      let fold t = fold_internal Sequence.fold t
      let fold' t = fold_internal Sequence.fold' t

      let filter t l ~f =
        fold
          t
          l
          ~init:(Set.empty (Set.comparator_s l))
          ~f:(fun acc ele ->
            match%map f ele with
            | true -> Set.add acc ele
            | false -> acc)
      ;;

      let filter' t l ~f = filter t l ~f:(Fn.compose return f)
      let iter t set ~f = fold t set ~f:(fun () data -> f data) ~init:()
      let iter' t set ~f = fold' t set ~f:(fun () data -> f data) ~init:()
    end

    module List = struct
      let fold_internal sequence_fold yield_timer list ~init ~f =
        let sequence = Core.Sequence.of_list list in
        sequence_fold yield_timer sequence ~init ~f
      ;;

      let fold t = fold_internal Sequence.fold t
      let fold' t = fold_internal Sequence.fold' t
      let iter t set ~f = fold t set ~f:(fun () data -> f data) ~init:()
      let iter' t set ~f = fold' t set ~f:(fun () data -> f data) ~init:()

      let filter t l ~how:`Sequential ~f =
        fold t l ~init:[] ~f:(fun acc ele ->
          match%map f ele with
          | true -> ele :: acc
          | false -> acc)
        >>| List.rev
      ;;

      let filter' t l ~how:`Sequential ~f =
        filter t l ~how:`Sequential ~f:(Fn.compose return f)
      ;;

      let filter_map t l ~how:`Sequential ~f =
        fold t l ~init:[] ~f:(fun acc ele ->
          match%map f ele with
          | Some new_ele -> new_ele :: acc
          | None -> acc)
        >>| List.rev
      ;;

      let filter_map' t l ~how:`Sequential ~f =
        filter_map t l ~how:`Sequential ~f:(Fn.compose return f)
      ;;

      let map t l ~how:`Sequential ~f =
        filter_map t l ~how:`Sequential ~f:(fun value ->
          Monad.map (f value) ~f:Option.return)
      ;;

      let map' t l ~how:`Sequential ~f = map t l ~how:`Sequential ~f:(Fn.compose return f)
      let concat_map t l ~how ~f = map t l ~how ~f >>| List.concat
      let concat_map' t l ~how ~f = concat_map t l ~how ~f:(Fn.compose return f)
      let partition_map t l ~how ~f = map t l ~how ~f >>| List.partition_map ~f:Fn.id
      let partition_map' t l ~how ~f = partition_map t l ~how ~f:(Fn.compose return f)

      let min_or_max_internal t l ~min_or_max =
        match l with
        | [] -> Monad.return None
        | hd :: tl ->
          fold' t tl ~init:hd ~f:(fun acc ele -> min_or_max acc ele)
          |> Monad.map ~f:Option.return
      ;;

      let max_elt t l ~compare =
        min_or_max_internal t l ~min_or_max:(Comparable.max compare)
      ;;

      let min_elt t l ~compare =
        min_or_max_internal t l ~min_or_max:(Comparable.min compare)
      ;;
    end
  end

  include Iterators
end

include Yield_timer_intf

module Without_yields = struct
  include Make (struct
      include Monad.Ident

      let default_yield = Fn.id

      let rec repeat_until_finished state f =
        match f state with
        | `Repeat state -> repeat_until_finished state f
        | `Finished result -> result
      ;;
    end)

  (* We can't use [max_representable_value] here, because it will lead to overflow when
     added to the current time, resulting in a time in the past and therefore always
     yielding (instead of never yielding). *)
  let without_yields = create ~yield_every:(Time_ns.Span.of_day 1000.) ()
end

include Make (struct
    type 'a t = 'a Deferred.t

    include Eager_deferred

    let default_yield = Async_kernel_scheduler.yield
  end)

open! Eager_deferred.Use

module Pipe = struct
  let iter_without_pushback t pipe ~f =
    repeat_until_finished t () (fun () ->
      match Pipe.read_now pipe with
      | `Ok a ->
        f a;
        return (`Repeat ())
      | `Eof -> return (`Finished ())
      | `Nothing_available ->
        let%bind (`Eof | `Ok) = Pipe.values_available pipe in
        return (`Repeat ()))
  ;;

  let fold_without_pushback t pipe ~init ~f =
    repeat_until_finished t init (fun accum ->
      match Pipe.read_now pipe with
      | `Ok a -> return (`Repeat (f accum a))
      | `Eof -> return (`Finished accum)
      | `Nothing_available ->
        let%bind (`Eof | `Ok) = Pipe.values_available pipe in
        return (`Repeat accum))
  ;;
end

module Pipe_with_writer_error = struct
  let iter_without_pushback t pipe ~f =
    repeat_until_finished t () (fun () ->
      match Pipe_with_writer_error.Early_error_bug.read_now pipe with
      | Error error -> return (`Finished (Error error))
      | Ok `Eof -> return (`Finished (Ok ()))
      | Ok (`Ok a) ->
        f a;
        return (`Repeat ())
      | Ok `Nothing_available ->
        (match%map Pipe_with_writer_error.values_available pipe with
         | Error error -> `Finished (Error error)
         | Ok `Eof -> `Finished (Ok ())
         | Ok `Ok -> `Repeat ()))
  ;;

  let fold_without_pushback t pipe ~init ~f =
    repeat_until_finished t init (fun accum ->
      match Pipe_with_writer_error.Early_error_bug.read_now pipe with
      | Error error -> return (`Finished (Error error))
      | Ok `Eof -> return (`Finished (Ok accum))
      | Ok (`Ok a) -> return (`Repeat (f accum a))
      | Ok `Nothing_available ->
        (match%map Pipe_with_writer_error.values_available pipe with
         | Error error -> `Finished (Error error)
         | Ok `Eof -> `Finished (Ok accum)
         | Ok `Ok -> `Repeat accum))
  ;;
end
