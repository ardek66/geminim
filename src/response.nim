type RespStatus* = enum
  RespNull
  RespCGI
  
  RespInputRequired = "10"
  RespSensitiveInput = "11"
  RespSuccess = "20"
  RespSuccessOther = "20"
  RespRedirect = "30"
  RespRedirectPerm = "31"
  RespTempError = "40"
  RespServerUnavailable = "41"
  RespCGIError = "42"
  RespProxyError = "43"
  RespSlowDown = "44"
  RespError = "50"
  RespNotFound = "51"
  RespGone = "52"
  RespProxyRefused = "53"
  RespMalformedRequest = "59"
  RespCertificateRequired = "60"
  RespNotAuthorised = "61"
  RespExpired = "62"
  RespInvalid = "63"

type Response* = object
  meta*: string
  case code*: RespStatus
  of RespSuccess:
    file*: File
  else: discard

proc response*(code: RespStatus, meta = ""): Response =
  Response(code: code, meta: meta)

proc `$`*(resp: Response): string =
  $resp.code & ' ' & resp.meta & "\r\n"
