(*
 * Copyright (c) 2015 Magnus Skjegstad <magnus@skjegstad.com>
 * Copyright (c) 2016 Qi Li            <ql272@cl.cam.ac.uk>
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

(* Structure
 * Jitsu
 *      \-vm (vm/dns configuration)
 *          \-[uuid]
 *              \-dns
 *                  \-[dns_name]
 *                      \-ttl
 *                      (+ other stats)
 *              \-config (this config is read by the virt. backend and contains optional parameters)
 *                  \ ...
 *              \-stop_mode
 *              \-response_delay (+ other stats)
 *              \-ip
 *     \-stats (various dynamic stats)
 *          \-[uuid]
 *              \-dns
 *          ...
*)


module Make (B : Irmin.S_MAKER) = struct
  module I = B(Irmin.Contents.String)(Irmin.Ref.String)(Irmin.Hash.SHA1)

  type t = {
    connection : string -> I.t;
    log : (string -> unit);
  }

  type id = string

  let get_float t path  =
    I.read t path >>= fun r ->
    match r with
    | None -> Lwt.return_none
    | Some s -> Lwt.return (Some (float_of_string s))

  let set_float t path f =
    I.update t path (string_of_float f)

  let default_log msg =
    Printf.printf "irmin_backend: %s\n" msg

  let create ?root:(root="irmin/test") ?log:(log=default_log) () =
    let task msg = Irmin.Task.create ~date:(Int64.of_float (Unix.gettimeofday ())) ~owner:"jitsu" msg in
    let config = Irmin_git.config ~root ~bare:true () in
    I.Repo.create config >>= I.master task >>= fun connection ->
    Lwt.return { connection ; log}

  let add_vm_domain t ~vm_uuid ~domain_name ~domain_ttl =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name] in
    I.update (it "Registering domain ttl") (path @ [ "ttl" ]) (string_of_int domain_ttl) >>= fun () ->
    Lwt.return_unit

  let list_of_hashtbl hashtbl =
    (* fold Hashtbl into (key, value list) list, where the list of values is all bindings for this key in the hash table.
     * The list of values is in inserted order, the key order is unspecified *)
    let keys = Hashtbl.fold (fun k _ l ->
        match (List.exists (fun s -> s = k) l) with (* fold hashtbl to list of unique keys*)
        | false -> l @ [k]
        | true -> l)
        hashtbl [] in
    List.fold_left (fun l key ->
        (* values returned from find_all is in reversed inserted order, so reverse list *)
        let bindings = List.rev (Hashtbl.find_all hashtbl key) in
        let values = List.fold_left (fun l v -> l @ [v]) [] bindings in
        l @ [(key, values)]
      ) [] keys

  let hashtbl_of_list lst =
    (* Insert key/values in Hastbl. List is expected to be in format (key, value list) list, as returned by list_of_hashtbl. *)
    let tbl = Hashtbl.create (List.length lst) in (* this length will be wrong if there are multiple bindings per key *)
    List.iter (fun row ->
        let key,value_list = row in
        List.iter (fun v ->
            Hashtbl.add tbl key v) value_list) lst;
    tbl

  let add_vm t ~vm_uuid ~vm_ip ~vm_stop_mode ~response_delay ~wait_for_key ~use_synjitsu ~vm_config =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.update (it "Registering VM stop mode")       (path @ [ "stop_mode" ]) (Gk_vm_stop_mode.to_string vm_stop_mode) >>= fun () ->
    I.update (it "Registering VM response delay")  (path @ [ "response_delay" ]) (string_of_float response_delay) >>= fun () ->
    I.update (it "Registering VM IP")              (path @ [ "ip" ]) (Ipaddr.V4.to_string vm_ip) >>= fun () ->
    let wait_for_key =
      match wait_for_key with
      | None -> ""
      | Some s -> s
    in
    I.update (it "Registering VM Xenstore wait key")    (path @ [ "wait_for_key" ]) wait_for_key >>= fun () ->
    I.update (it "Registering VM Synjitsu mode")    (path @ [ "use_synjitsu" ]) (string_of_bool use_synjitsu) >>= fun () ->
    let path = path @ [ "config" ] in
    let config_list = list_of_hashtbl vm_config in
    Lwt_list.iter_s (fun row ->
        let k,value_list = row in
        Lwt_list.iteri_s (fun i v ->
            I.update (it (Printf.sprintf "Registering extra config value %s (%d)" k i))
              (path @ [ k ; (string_of_int i) ]) v
          ) value_list)
      config_list
    >>= fun () ->
    Lwt.return_unit

  let get_stop_mode t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.read (it "Get stop mode") (path @ [ "stop_mode" ]) >>= fun r ->
    match r with
    | None -> Lwt.return Gk_vm_stop_mode.Unknown
    | Some s -> Lwt.return (Gk_vm_stop_mode.of_string s)

  let set_stop_mode t ~vm_uuid stop_mode =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.update (it "Set stop mode") (path @ [ "stop_mode" ]) (Gk_vm_stop_mode.to_string stop_mode)

  let get_use_synjitsu t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.read (it "Get VM Synjitsu mode") (path @ [ "use_synjitsu" ]) >>= fun r ->
    match r with
    | None -> Lwt.return false
    | Some s ->
      try
        if s = "1" then Lwt.return_true else
        if s = "0" then Lwt.return_false else
          Lwt.return (bool_of_string s)
      with
      | Invalid_argument _ -> Lwt.return_false

  let get_wait_for_key t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.read (it "Get Xenstore wait key") (path @ [ "wait_for_key" ]) >>= fun r ->
    match r with
    | None -> Lwt.return_none
    | Some s -> if s = "" then Lwt.return_none else Lwt.return (Some s)

  let get_ip t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.read (it "Get VM IP") (path @ [ "ip" ]) >>= fun r ->
    match r with
    | None -> Lwt.return_none
    | Some s -> Lwt.return (Ipaddr.V4.of_string s)

  let set_ip t ~vm_uuid ip =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ] in
    I.update (it "Set VM IP") (path @ [ "ip" ]) (Ipaddr.V4.to_string ip) >>= fun () ->
    Lwt.return_unit

  let get_last_request_timestamp t ~vm_uuid ~domain_name =
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name] in
    get_float (it "Get last request timestamp") (path @ [ "last_request_ts" ])

  let set_last_request_timestamp t ~vm_uuid ~domain_name last_request_ts =
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name] in
    set_float (it "Set last request timestamp") (path @ [ "last_request_ts" ]) last_request_ts

  let get_start_timestamp t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ] in
    get_float (it "Get start timestamp") (path @ [ "start_ts" ])

  let set_start_timestamp t ~vm_uuid start_ts =
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ] in
    set_float (it "Set start timestamp") (path @ [ "start_ts" ]) start_ts

  let get_total_starts t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ] in
    I.read (it "Get total starts") (path @ [ "total_starts" ]) >>= fun r ->
    match r with
    | None -> Lwt.return 0
    | Some s -> Lwt.return (int_of_string s)

  let inc_total_starts t ~vm_uuid =
    (* TODO Should use transaction / view *)
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ] in
    get_total_starts t ~vm_uuid >>= fun starts ->
    I.update (it "Increase total starts") (path @ [ "total_starts" ]) (string_of_int (starts + 1))

  let get_total_requests t ~vm_uuid ~domain_name =
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name] in
    I.read (it "Get total requests") (path @ [ "total_requests" ]) >>= fun r ->
    match r with
    | None -> Lwt.return 0
    | Some s -> Lwt.return (int_of_string s)

  let inc_total_requests t ~vm_uuid ~domain_name =
    (* TODO Should use transaction / view *)
    let it = t.connection in
    let path = [ "jitsu" ; "stats" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name] in
    get_total_requests t ~vm_uuid ~domain_name >>= fun total_requests ->
    I.update (it "Increase total requests") (path @ [ "total_requests" ]) (string_of_int (total_requests + 1))

  let get_ttl t ~vm_uuid ~domain_name =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name ] in
    I.read (it "Get Domain TTL") (path @ [ "ttl" ]) >>= fun r ->
    match r with
    | None -> Lwt.return 0
    | Some s -> Lwt.return (int_of_string s)

  let set_ttl t ~vm_uuid ~domain_name ttl =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "domain" ; domain_name] in
    I.update (it "Set Domain TTL") (path @ [ "ttl" ]) (string_of_int ttl) >>= fun () ->
    Lwt.return_unit

  let get_response_delay t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "response_delay" ] in
    get_float (it "Get VM response delay") path >>= fun d ->
    match d with
    | None -> Lwt.return 0.0
    | Some f -> Lwt.return f

  let set_response_delay t ~vm_uuid response_delay =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "response_delay" ] in
    set_float (it "Set VM response delay") path response_delay

  (** Get a list of sub-key names as strings from an Irmin path *)
  let get_key_names t path =
    let it = t.connection in
    I.list (it "Retrieving key list") path >>= fun key_list ->
    Lwt_list.filter_map_s (fun v ->
        match (Irmin.Path.String_list.rdecons v) with
        | None -> Lwt.return None
        | Some (_,key) -> Lwt.return (Some key)
      ) key_list

  let get_vm_config t ~vm_uuid =
    let it = t.connection in
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "config" ] in
    get_key_names t path
    >>= fun config_keys ->
    Lwt_list.fold_left_s (fun l key ->
        get_key_names t (path @ [key]) >>= fun value_keys -> (* get value keys, expected to be ints 0-n *)
        let value_counter = List.sort (fun a b -> (Int64.compare (Int64.of_string a) (Int64.of_string b))) value_keys in (* sort by numeric order *)
        Lwt_list.fold_left_s (fun l i ->
            I.read (it (Printf.sprintf "Read config value %s (%s)" key i)) (path @ [ key ; i ]) >>= fun r ->
            match r with
            | None -> Lwt.return l
            | Some s -> Lwt.return (l @ [s])
          ) [] value_counter >>= fun values ->
        Lwt.return (l @ [(key, values)])
      ) [] config_keys
    >>= fun folded_hashtbl ->
    Lwt.return (hashtbl_of_list folded_hashtbl)

  let get_vm_list t =
    let path = [ "jitsu" ; "vm" ] in
    get_key_names t path >>= fun key_names ->
    Lwt_list.filter_map_s (fun v ->
        match (Uuidm.of_string v) with
        | None -> t.log (Printf.sprintf "Unable to parse UUID %s, VM ignored" v); Lwt.return_none
        | Some uuid -> Lwt.return (Some uuid)
      ) key_names

  let get_vm_domain_name_list t ~vm_uuid =
    let path = [ "jitsu" ; "vm" ; (Uuidm.to_string vm_uuid) ; "domain" ] in
    get_key_names t path >>= fun domain_names ->
    return domain_names

end
