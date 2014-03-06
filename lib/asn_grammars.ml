open Asn

type bits = Cstruct.t

let def  x = function None -> x | Some y -> y
let def' x = fun y -> if y = x then None else Some y

let projections encoding asn =
  let c = codec encoding asn in (decode c, encode c)


(*
 * RSA
 *)

let other_prime_infos =
  sequence_of @@
    (sequence3
      (required ~label:"prime"       big_natural)
      (required ~label:"exponent"    big_natural)
      (required ~label:"coefficient" big_natural))

let rsa_private_key =
  let open Cryptokit.RSA in

  let f (_, (n, (e, (d, (p, (q, (dp, (dq, (qinv, _))))))))) =
    let size = String.length n * 8 in
    { size; n; e; d; p; q; dp; dq; qinv }

  and g { size; n; e; d; p; q; dp; dq; qinv } =
    (0, (n, (e, (d, (p, (q, (dp, (dq, (qinv, None))))))))) in

  map f g @@
  sequence @@
      (required ~label:"version"         int)
    @ (required ~label:"modulus"         big_natural)  (* n    *)
    @ (required ~label:"publicExponent"  big_natural)  (* e    *)
    @ (required ~label:"privateExponent" big_natural)  (* d    *)
    @ (required ~label:"prime1"          big_natural)  (* p    *)
    @ (required ~label:"prime2"          big_natural)  (* q    *)
    @ (required ~label:"exponent1"       big_natural)  (* dp   *)
    @ (required ~label:"exponent2"       big_natural)  (* dq   *)
    @ (required ~label:"coefficient"     big_natural)  (* qinv *)
   -@ (optional ~label:"otherPrimeInfos" other_prime_infos)


let rsa_public_key =
  let open Cryptokit.RSA in

  let f (n, e) =
    let size = String.length n * 8 in
    { size; n; e; d = ""; p = ""; q = ""; dp = ""; dq = ""; qinv = "" }

  and g { n; e } = (n, e) in

  map f g @@
  sequence2
    (required ~label:"modulus"        big_natural)
    (required ~label:"publicExponent" big_natural)

let (rsa_private_of_cstruct, rsa_private_to_cstruct) =
  projections der rsa_private_key

let (rsa_public_of_cstruct, rsa_public_to_cstruct) =
  projections der rsa_public_key


(*
 * X509 certs
 *)

(* This type really conflates two things: the set of pk algos that describe the
 * public key, and the set of hash+pk algo combinations that describe digests.
 * The two are conflated because they are generated by the same ASN grammar,
 * AlgorithmIdentifier, to keep things close to the standards.
 *
 * It's expected that downstream code with pick a subset and add a catch-all
 * that handles unsupported algos anyway.
 *)

type algorithm =
  (* pk algos *)
  | RSA
  | EC_pub_key of OID.t (* should translate the oid too *)
  (* sig algos *)
  | MD2_RSA
  | MD4_RSA
  | MD5_RSA
  | RIPEMD160_RSA
  | SHA1_RSA
  | SHA256_RSA
  | SHA384_RSA
  | SHA512_RSA
  | SHA224_RSA
  | ECDSA_SHA1
  | ECDSA_SHA224
  | ECDSA_SHA256
  | ECDSA_SHA384
  | ECDSA_SHA512

type name_component =
  | Common_name      of string
  | Surname          of string
  | Serial           of string
  | Country          of string
  | Locality         of string
  | Province         of string
  | Org              of string
  | Org_unit         of string
  | Title            of string
  | Given_name       of string
  | Initials         of string
  | Generation       of string
  | DN_qualifier     of string
  | Pseudonym        of string
  | Domain_component of string
  | Other            of OID.t * string

type tBSCertificate = {
  version    : [ `V1 | `V2 | `V3 ] ;
  serial     : Num.num ;
  signature  : algorithm ;
  issuer     : name_component list ;
  validity   : time * time ;
  subject    : name_component list ;
  pk_info    : algorithm * bits ;
  issuer_id  : bits option ;
  subject_id : bits option ;
  extensions : (oid * bool * Cstruct.t) list
}

type certificate = {
  tbs_cert       : tBSCertificate ;
  signature_algo : algorithm ;
  signature_val  : bits
}

(* XXX
 *
 * PKCS1/RFC5280 allows params to be `ANY', depending on the algorithm.  I don't
 * know of one that uses anything other than NULL and OID, however, so we accept
 * only that.
 *)

let algorithm_identifier =
  let open Registry in

  let unit = Some (`C1 ()) in

  let f = function
    | (oid, Some (`C2 oid')) when oid = ANSI_X9_62.ec_pub_key -> EC_pub_key oid'
    | (oid, _) when oid = PKCS1.rsa_encryption  -> RSA

    | (oid, _) when oid = PKCS1.md2_rsa_encryption       -> MD2_RSA
    | (oid, _) when oid = PKCS1.md4_rsa_encryption       -> MD4_RSA
    | (oid, _) when oid = PKCS1.md5_rsa_encryption       -> MD5_RSA
    | (oid, _) when oid = PKCS1.ripemd160_rsa_encryption -> RIPEMD160_RSA
    | (oid, _) when oid = PKCS1.sha1_rsa_encryption      -> SHA1_RSA
    | (oid, _) when oid = PKCS1.sha256_rsa_encryption    -> SHA256_RSA
    | (oid, _) when oid = PKCS1.sha384_rsa_encryption    -> SHA384_RSA
    | (oid, _) when oid = PKCS1.sha512_rsa_encryption    -> SHA512_RSA
    | (oid, _) when oid = PKCS1.sha224_rsa_encryption    -> SHA224_RSA

    | (oid, _) when oid = ANSI_X9_62.ecdsa_sha1   -> ECDSA_SHA1
    | (oid, _) when oid = ANSI_X9_62.ecdsa_sha224 -> ECDSA_SHA224
    | (oid, _) when oid = ANSI_X9_62.ecdsa_sha256 -> ECDSA_SHA256
    | (oid, _) when oid = ANSI_X9_62.ecdsa_sha384 -> ECDSA_SHA384
    | (oid, _) when oid = ANSI_X9_62.ecdsa_sha512 -> ECDSA_SHA512

    | (oid, _) -> parse_error @@
        Printf.sprintf "unknown algorithm (%s) or unexpected params"
                       (OID.to_string oid)

  and g = function
    | EC_pub_key id -> (ANSI_X9_62.ec_pub_key, Some (`C2 id))
    | RSA           -> (PKCS1.rsa_encryption           , unit)
    | MD2_RSA       -> (PKCS1.md2_rsa_encryption       , unit)
    | MD4_RSA       -> (PKCS1.md4_rsa_encryption       , unit)
    | MD5_RSA       -> (PKCS1.md5_rsa_encryption       , unit)
    | RIPEMD160_RSA -> (PKCS1.ripemd160_rsa_encryption , unit)
    | SHA1_RSA      -> (PKCS1.sha1_rsa_encryption      , unit)
    | SHA256_RSA    -> (PKCS1.sha256_rsa_encryption    , unit)
    | SHA384_RSA    -> (PKCS1.sha384_rsa_encryption    , unit)
    | SHA512_RSA    -> (PKCS1.sha512_rsa_encryption    , unit)
    | SHA224_RSA    -> (PKCS1.sha224_rsa_encryption    , unit)
    | ECDSA_SHA1    -> (ANSI_X9_62.ecdsa_sha1          , unit)
    | ECDSA_SHA224  -> (ANSI_X9_62.ecdsa_sha224        , unit)
    | ECDSA_SHA256  -> (ANSI_X9_62.ecdsa_sha256        , unit)
    | ECDSA_SHA384  -> (ANSI_X9_62.ecdsa_sha384        , unit)
    | ECDSA_SHA512  -> (ANSI_X9_62.ecdsa_sha512        , unit)
  in

  map f g @@
  sequence2
    (required ~label:"algorithm" oid)
    (optional ~label:"params"
      (choice2 null oid))

let extensions =
  let extension =
    map (fun (oid, b, v) -> (oid, def  false b, v))
        (fun (oid, b, v) -> (oid, def' false b, v)) @@
    sequence3
      (required ~label:"id"       oid)
      (optional ~label:"critical" bool) (* default false *)
      (required ~label:"value"    octet_string)
  in
  sequence_of extension


(* See rfc5280 section 4.1.2.4. *)
let directory_name =
  let f = function | `C1 s -> s | `C2 s -> s | `C3 s -> s
                   | `C4 s -> s | `C5 s -> s | `C6 s -> s
  and g s = `C1 s in
  map f g @@
  choice6
    utf8_string printable_string
    ia5_string universal_string teletex_string bmp_string


(* We flatten the sequence-of-set-of-tuple here into a single list.
 * This means that we can't write non-singleton sets back.
 * Does anyone need that, ever?
 *)

let name =
  let open Registry in

  let a_f = function
    | (oid, x) when oid = X520.common_name              -> Common_name  x
    | (oid, x) when oid = X520.surname                  -> Surname      x
    | (oid, x) when oid = X520.serial_number            -> Serial       x
    | (oid, x) when oid = X520.country_name             -> Country      x
    | (oid, x) when oid = X520.locality_name            -> Locality     x
    | (oid, x) when oid = X520.state_or_province_name   -> Province     x
    | (oid, x) when oid = X520.organization_name        -> Org          x
    | (oid, x) when oid = X520.organizational_unit_name -> Org_unit     x
    | (oid, x) when oid = X520.title                    -> Title        x
    | (oid, x) when oid = X520.given_name               -> Given_name   x
    | (oid, x) when oid = X520.initials                 -> Initials     x
    | (oid, x) when oid = X520.generation_qualifier     -> Generation   x
    | (oid, x) when oid = X520.dn_qualifier             -> DN_qualifier x
    | (oid, x) when oid = X520.pseudonym                -> Pseudonym    x
    | (oid, x) when oid = domain_component              -> Domain_component x
    | (oid, x) -> Other (oid, x)

  and a_g = function
    | Common_name      x -> (X520.common_name              , x)
    | Surname          x -> (X520.surname                  , x)
    | Serial           x -> (X520.serial_number            , x)
    | Country          x -> (X520.country_name             , x)
    | Locality         x -> (X520.locality_name            , x)
    | Province         x -> (X520.state_or_province_name   , x)
    | Org              x -> (X520.organization_name        , x)
    | Org_unit         x -> (X520.organizational_unit_name , x)
    | Title            x -> (X520.title                    , x)
    | Given_name       x -> (X520.given_name               , x)
    | Initials         x -> (X520.initials                 , x)
    | Generation       x -> (X520.generation_qualifier     , x)
    | DN_qualifier     x -> (X520.dn_qualifier             , x)
    | Pseudonym        x -> (X520.pseudonym                , x)
    | Domain_component x -> (domain_component              , x)
    | Other (oid, x)     -> (oid, x)
  in

  let attribute_tv =
    map a_f a_g @@
    sequence2
      (required ~label:"attr type"  oid)
      (* This is ANY according to rfc5280. *)
      (required ~label:"attr value" directory_name) in
  let rd_name      = set_of attribute_tv in
  let rdn_sequence =
    map List.concat (List.map (fun x -> [x]))
    @@
    sequence_of rd_name
  in
  rdn_sequence (* A vacuous choice, in the standard. *)

(* XXX really default other versions to V1 or bail out? *)
let version =
  map (function 2 -> `V2 | 3 -> `V3 | _ -> `V1)
      (function `V2 -> 2 | `V3 -> 3 | _ -> 1)
  int

let certificate_sn = integer

let time =
  map (function `C1 t -> t | `C2 t -> t) (fun t -> `C2 t)
      (choice2 utc_time generalized_time)

let validity =
  sequence2
    (required ~label:"not before" time)
    (required ~label:"not after"  time)

let subject_pk_info =
  sequence2
    (required ~label:"algorithm" algorithm_identifier)
    (required ~label:"subjectPK" bit_string')

let unique_identifier = bit_string'

let tBSCertificate =
  let f = fun (a, (b, (c, (d, (e, (f, (g, (h, (i, j))))))))) ->
    let extn = match j with None -> [] | Some xs -> xs
    in
    { version    = def `V1 a ; serial     = b ;
      signature  = c         ; issuer     = d ;
      validity   = e         ; subject    = f ;
      pk_info    = g         ; issuer_id  = h ;
      subject_id = i         ; extensions = extn }

  and g = fun
    { version    = a ; serial     = b ;
      signature  = c ; issuer     = d ;
      validity   = e ; subject    = f ;
      pk_info    = g ; issuer_id  = h ;
      subject_id = i ; extensions = j } ->
    let extn = match j with [] -> None | xs -> Some xs
    in
    (def' `V1 a, (b, (c, (d, (e, (f, (g, (h, (i, extn)))))))))
  in

  map f g @@
  sequence @@
      (optional ~label:"version"       @@ explicit 0 version) (* default v1 *)
    @ (required ~label:"serialNumber"  @@ certificate_sn)
    @ (required ~label:"signature"     @@ algorithm_identifier)
    @ (required ~label:"issuer"        @@ name)
    @ (required ~label:"validity"      @@ validity)
    @ (required ~label:"subject"       @@ name)
    @ (required ~label:"subjectPKInfo" @@ subject_pk_info)
      (* if present, version is v2 or v3 *)
    @ (optional ~label:"issuerUID"     @@ implicit 1 unique_identifier)
      (* if present, version is v2 or v3 *)
    @ (optional ~label:"subjectUID"    @@ implicit 2 unique_identifier)
      (* v3 if present *)
   -@ (optional ~label:"extensions"    @@ explicit 3 extensions)

let (tbs_certificate_of_cstruct, tbs_certificate_to_cstruct) =
  projections ber tBSCertificate


let certificate =

  let f (a, b, c) =
    if a.signature <> b then
      parse_error "signatureAlgorithm != tbsCertificate.signature"
    else
      { tbs_cert = a; signature_algo = b; signature_val = c }

  and g { tbs_cert = a; signature_algo = b; signature_val = c } = (a, b, c) in

  map f g @@
  sequence3
    (required ~label:"tbsCertificate"     tBSCertificate)
    (required ~label:"signatureAlgorithm" algorithm_identifier)
    (required ~label:"signatureValue"     bit_string')

let (certificate_of_cstruct, certificate_to_cstruct) =
  projections ber certificate

(* XXX this should really be pushed into certificate decode proper, instead of
 * being called as a separate function on it, after we fish out the relevant
 * oids and the corresponding public key grammars. *)

let rsa_public_of_cert cert =
  match cert.tbs_cert.pk_info with
  | (RSA, bits) ->
    ( match rsa_public_of_cstruct bits with
      | Some (k, _) -> k
      | None -> assert false )
  | _ -> assert false

let pkcs1_digest_info =
  sequence2
    (required ~label:"digestAlgorithm" algorithm_identifier)
    (required ~label:"digest"          octet_string)

let (pkcs1_digest_info_of_cstruct, pkcs1_digest_info_to_cstruct) =
  projections der pkcs1_digest_info

