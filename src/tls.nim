import openssl, strutils, parseutils, net, asyncnet
export openssl

type
  CertError* = enum
    CertOK
  
    CertExpired
    CertInvalid

  DigestType* = enum
    DigestErr
    DigestNull = "null"

    DigestMD1 = "md1"
    DigestSHA1 = "sha1"
    DigestSHA256 = "sha256"
    DigestSHA512 = "sha512"

  Authorisation* = tuple
    typ: DigestType
    digest: string

proc printf(formatstr: cstring) {.importc: "printf", varargs,
                                  header: "<stdio.h>".}

proc EVP_get_digestbyname(name: cstring): PEVP_MD {.importc, dynlib: DLLUTilName.}
proc EVP_MD_size(md: PEVP_MD): cuint {.importc, dynlib: DLLUtilName.}
proc EVP_Digest(data: pointer, count: cuint, md: cstring,
                size: ptr cuint, typ: PEVP_MD, impl: SslPtr = nil): cint {.importc, dynlib: DLLUtilName.}
proc PEM_read_bio_X509(bio: BIO, x: PX509, password_cb: cint, u: pointer): PX509 {.importc, dynlib: DLLSSLName.}
proc SSL_CTX_set_verify_depth(ctx: SslCtx, depth: cint) {.importc, dynlib: DLLSSLName.}
proc verify_cb(preverify_ok: int, ctx: pointer): int{.cdecl.} = 1

proc i2d_X509(cert: PX509): string =
  ## encode `cert` to DER string
  let encoded_length = i2d_X509(cert, nil)
  result = newString(encoded_length)
  var q = result.cstring
  let o = cast[ptr ptr uint8](addr q)
  let length = i2d_X509(cert, o)
  if length.int < 0:
    raise newException(ValueError, "X.509 certificate encoding failed")

proc prepareGeminiCtx*(ctx: SslContext) =
  ctx.context.SSL_CTX_set_verify(SslVerifyPeer, verify_cb)
  ctx.context.SSL_CTX_set_verify_depth(0)

proc getVerifyResult*(socket: AsyncSocket): CertError =
  let err = socket.sslHandle.SSL_get_verify_result()

  result =
    case err
    of X509_V_OK, X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT: CertOK
    of X509_V_ERR_CERT_HAS_EXPIRED: CertExpired
    else: CertInvalid

proc getPeerCertificate*(socket: AsyncSocket): Certificate =
  socket.sslHandle.SSL_get_peer_certificate.i2d_x509

proc getDigest*(cert: Certificate, typ: DigestType): string =
  let evp_typ = EVP_get_digestbyname(cstring($typ))
  result = newString(evp_typ.EVP_MD_size)
  
  var mdLen: cuint
  let err = EVP_Digest(cert.cstring, cert.len.cuint, result.cstring, addr mdLen, evp_typ)
  if(err < 1 or result.len != mdLen.int):
    raise newException(ValueError, "Digest failed.")

  return result.toHex()
