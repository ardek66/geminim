import openssl, strutils, asyncdispatch
include asyncnet
export openssl

proc PEM_read_bio_X509(bio: BIO, x: PX509, password_cb: cint, u: pointer): PX509 {.importc, dynlib: DLLSSLName.}
proc X509_getm_notBefore(x: PX509): pointer {.importc, dynlib: DLLSSLName.}
proc X509_getm_notAfter(x: PX509): pointer {.importc, dynlib: DLLSSLName.}
proc X509_cmp_current_time(time: pointer): cint {.importc, dynlib: DLLSSLName.}
proc X509_verify_cert(ctx: PX509_STORE) {.importc, dynlib: DLLSSLName.}
proc X509_STORE_CTX_get_error(ctx: PX509_STORE): cint {.importc, dynlib: DLLSSLName.}
proc X509_STORE_CTX_set_error(ctx: PX509_STORE, error: cint) {.importc, dynlib: DLLSSLName.}
proc SSL_CTX_set_session_id_context*(ctx: SslCtx, id: string, idLen: int) {.importc, dynlib: DLLSSLName.}
proc SSL_CTX_set_cert_verify_callback*(ctx: SslCtx, cb: proc(ctx: PX509_STORE, args: pointer): int {.cdecl.}, args: pointer) {.importc, dynlib: DLLSSLName.}

proc verify_cb*(ctx: PX509_STORE, args: pointer): int {.cdecl.} =
  ctx.X509_verify_cert()
  if ctx.X509_STORE_CTX_get_error == 18:
    ctx.X509_STORE_CTX_set_error(0)
  return 1


proc getX509Cert*(cert: PX509): string =
  if cert == nil: return
  return cert.i2d_X509

proc getX509Cert*(data: string): string =
  let
    bio = BIO_new_mem_buf(data.cstring, data.len.cint)
    x509 = bio.PEM_read_bio_X509(nil, 0, nil)
  bioFreeAll(bio)

  return getX509Cert(x509)

proc getPeerCertificate*(socket: AsyncSocket): string =
  if socket.sslHandle.SSL_get_verify_result() != X509_V_OK:
    return
  
  return socket.sslHandle.SSL_get_peer_certificate().getX509Cert()

proc parsePEM*(data: string): seq[string] =
  const
    beginSep = "-----BEGIN CERTIFICATE-----"
    endSep = "-----END CERTIFICATE-----"
  
  result = @[]
  var parseTop = 0
  while parseTop < data.len:
    let beginMark = data.find(beginSep, parseTop)
    if beginMark == -1: return
    let endMark = data.find(endSep, beginMark + beginSep.len)
    if endMark == -1: return

    result.add data[beginMark..endMark+endSep.len].getX509Cert()
    parseTop = endMark + endSep.len

proc certStillInvalid*(cert: string): bool =
  let time = cert.d2i_x509.X509_getm_notBefore()
  return time.X509_cmp_current_time() == 1

proc certExpired*(cert: string): bool =
  let time = cert.d2i_x509.X509_getm_notAfter()
  return time.X509_cmp_current_time() == -1
