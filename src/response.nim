import streams, mimetypes, os
export streams

type RespStatus* = enum
  StatusNull
  StatusInputRequired = "10"
  StatusSuccess = "20"
  StatusRedirect = "30"
  StatusRedirectPerm = "31"
  StatusTempError = "40"
  StatusError = "50"
  StatusNotFound = "51"
  StatusProxyRefused = "53"
  StatusMalformedRequest = "59"

type Response* = object
  meta*: string
  case code*: RespStatus
  of StatusSuccess:
    fileStream*: FileStream
  else: discard

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

template strResp*(code: RespStatus, meta: string): string =
  $code & ' ' & meta & "\r\n"

template response*(a, b: untyped): untyped =
  Response(code: a, meta: b)

proc response*(path: string): Response =
  result = response(StatusSuccess, m.getMimetype(path.splitFile.ext))
  result.fileStream = newFileStream(path)

const
  SuccessResp* = strResp(StatusSuccess, "text/gemini")
  TempErrorResp* = strResp(StatusTempError, "INTERNAL ERROR")
