import http show *
import http.status_codes show *
import net
import net.tcp
import encoding.base64
import encoding.json
import log

OPTIONS ::= "OPTIONS"

logger_/log.Logger ::= log.default.with_name "rest server"

/**
A server that handles REST requests.

#Paths
To add a path to the rest server, use one of the $get, $post, $put, $delete or $options methods. These all take
a handler lambda that actually handles the request. The handler is called when a request comes in that matches
the path. The handler takes two arguments a request of type RestRequest and a response of type RestResponse.
All paths must start with a "/"

Paths can contain path variables, for example `get "/blog/:id"` will match requests starting with /blog, and the
:id will be part of the parameters 

#Error handling
If a handler throws an exception while processing the request, the RestServer will generate a 500 response with 
a json body consisting of the error string value, the trace base64 encoded and a user supplied data field
```json
{
  "value": "<<The exception value>>",
  "trace": "<<The trace for the exception base64 encoded for easy external decoding>>",
  "data": "<<User supplied exception_data handler result, for example including futher diagnostics>>
}
```

#Examples
```
main:
  rest := RestServer (network.tcp_listen 80) ::
     // Whatever this lambda returns is added to the body json of the 500 reply on exception
     log_system.get_recent_logs 25 // For example return the last 25 logs generated prior to the exception

  rest.get "/hello" :: | req/RestRequest resp/RestResponse |
    resp.write "World"

  rest.post "/blog" :: | req/RestRequest resp/RestResponse |
    blogs.add req.body.read
    resp.write "Ok"

  rest.get "/blog/:id" :: | req/RestRequest resp/RestResponse |
    resp.write
        blogs.get req.parameters[":id"]
```
*/
class RestServer:
  server_/Server? := null
  requests_paths_/Map := {:}
  exception_data_/Lambda

  /**
  Creates a new RestServer listening on $socket. Optionally provide an $exception_data lambda to provide additional information
  when catching an exception
  */
  constructor socket/tcp.ServerSocket exception_data/Lambda?=null:
    server_ = Server
    if exception_data: exception_data_ = exception_data
    else: exception_data_ = :: null
    run_ socket
    List
  
  /**
  Adds a GET $path to this rest server served by $handler
  */
  get path/string handler/Lambda: add_request_ GET path handler

  /**
  Adds a POST $path to this rest server served by $handler
  */
  post path/string handler/Lambda: add_request_ POST path handler

  /**
  Adds a PUT $path to this rest server served by $handler
  */
  put path/string handler/Lambda: add_request_ PUT path handler

  /**
  Adds a DELETE $path to this rest server served by $handler
  */
  delete path/string handler/Lambda: add_request_ DELETE path handler

  /**
  Adds an OPTIONS $path to this rest server served by $handler
  */
  options path/string handler/Lambda: add_request_ OPTIONS path handler

  add_request_ method/string path/string handler/Lambda:
    paths/Paths_? := requests_paths_.get method
    if not paths: 
        paths = Paths_ this
        requests_paths_[method] = paths

    path_elements := split_path_in_add_ path
    paths.add path_elements handler

    logger_.info "Added path $path"

  run_ socket/tcp.ServerSocket:
    task::
      server_.listen socket :: | req res |
        dispatch_ req res

  split_path_in_add_ path/string:
    path_elements := path.split "/"
    if path_elements.size < 2 or path_elements[0] != "": throw "Request paths must start with a /"
    return path_elements[1..]

  dispatch_ req/Request res/ResponseWriter:
    logger_.info "Received $req.method request for path $req.path"
    paths/Paths_? := requests_paths_.get req.method
    if not paths:
        s404_ res
        return

    path_elements := req.path.split "/"
    result := paths.dispatch 
        path_elements[1..] 
        RestRequest.private_ req 
        RestResponse.private_ res
    if not result:
      s404_ res

  s404_ resp/ResponseWriter:
    logger_.info "Path look up failed, returning NOT FOUND"
    resp.write_headers 404

COLON_/int ::= ":"[0]

class Paths_:
  // leaf structures
  handlers_/Map := {:}
  tail_wildcard_/TailWildcard_? := null

  // intermediate structures
  sub_paths_/Map := {:}
  infix_wildcards_/Map := {:}

  rest/RestServer

  constructor .rest:

  add path/List handler/Lambda:
    if path.size == 1:
      // Tail
      if path[0][0] == COLON_:
        if tail_wildcard_: throw "Multiple tail wild cards for path not supported"
        tail_wildcard_ = TailWildcard_ path[0] handler
        logger_.debug "added wildcard $path[0]"
      else:
        handlers_[path[0]] = handler
    else:
      map/Map := (path[0][0] == COLON_ ? infix_wildcards_ : sub_paths_)

      paths/Paths_? := map.get path[0]
      if not paths:
        paths = Paths_ rest
        map[path[0]] = paths
      
      paths.add path[1..] handler

  dispatch path/List req/RestRequest resp/RestResponse -> bool:
    logger_.debug "dispatching: $path"
    if path.size == 1:
      if handlers_.contains path[0]:
        invoke_handler handlers_[path[0]] req resp
        return true
      else if tail_wildcard_:
        req.parameters[tail_wildcard_.var_name] = path[0]
        invoke_handler tail_wildcard_.handler req resp
        return true
    else:
      if sub_paths_.contains path[0]:
        paths/Paths_ := sub_paths_[path[0]]
        if paths.dispatch path[1..] req resp: return true

      infix_wildcards_.keys.do:
        paths/Paths_ := infix_wildcards_[it]

        // Quick and dirty, this has some issues with multiple parameter names in the map and potential overwrites.
        req.parameters[it] = path[0]
        if paths.dispatch path[1..] req resp: return true

    return false

  invoke_handler handler/Lambda req/RestRequest res/RestResponse:
    try:
      handler.call req res
    finally: | is_exception e |
      if is_exception: 
        try:
          msg := json.encode {
            "value": e.value,
            "trace": base64.encode e.trace,
            "data": (rest.exception_data_.call)
          }
          res.respond 500 msg.to_string_non_throwing
        finally: | is_exception e |
          if is_exception:
            logger_.error "Received error in error handler. $e.value, trace: $(base64.encode e.trace)"
          // Ignore, if the handler already replied before throwing and exception, we ignore the exception
          return


/**
Represents the request from the client
*/
class RestRequest:
  /**
  Provides access to the request from the pgk-http package
  */
  http_req/Request
  parameters/Map := {:}

  constructor.private_ .http_req/Request:

/**
Represents the response to the client. Methods help build the response
*/
class RestResponse:
  /**
  Provides access to the response writer from the pgk-http package
  */
  http_res/ResponseWriter

  constructor.private_ .http_res:

  /**
  Sets the content type of the response to $content_type
  */
  content_type content_type/string:
    http_res.headers.set "Content-Type" content_type

  /**
  Sends the standard 200 message response with $body
  */
  ok body/any:
    respond STATUS_OK body

  /**
  Sends a response with a $code and $body
  */
  respond code/int body/any:
    if body is string or body is ByteArray:
      http_res.headers.set "Content-Length" "$body.size"

    http_res.write_headers code
    http_res.write body



class TailWildcard_:
  var_name/string
  handler/Lambda
  constructor .var_name .handler:

