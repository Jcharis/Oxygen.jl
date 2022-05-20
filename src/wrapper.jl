module Wrapper
    import HTTP
    import JSON3
    import Sockets

    include("util.jl")
    using .Util

    include("fileutil.jl")
    using .FileUtil

    export @get, @post, @put, @patch, @delete, @register, @route, @mount, @staticfiles, serve, internalrequest, queryparams, binary, text, json, html

    # define REST endpoints to dispatch to "service" functions
    const ROUTER = HTTP.Router()

    "Directly call one of our other endpoints registerd with the router"
    function internalrequest(req::HTTP.Request, suppressErrors::Bool=false)
        return DefaultHandler(req, suppressErrors)
    end

    "start the webserver"
    function serve(host=Sockets.localhost, port=8081, suppressErrors::Bool=false; kwargs...)
        println("Starting server: http://$host:$port")
        HTTP.serve(req -> DefaultHandler(req, suppressErrors), host, port, kwargs...)
    end

    function serve(handler::Function, host=Sockets.localhost, port=8081; kwargs...)
        println("Starting server: http://$host:$port")
        HTTP.serve(req -> handler(req, ROUTER, DefaultHandler), host, port, kwargs...)
    end

    function DefaultHandler(req::HTTP.Request, suppressErrors::Bool=false)
        try
            response_body = HTTP.handle(ROUTER, req, suppressErrors)
            # if a raw HTTP.Response object is returned, then don't do any extra processing on it
            if isa(response_body, HTTP.Messages.Response)
                return response_body 
            elseif isa(response_body, String)
                headers = ["Content-Type" => "text/plain; charset=utf-8"]
                return HTTP.Response(200, headers , body=response_body)
            else 
                body = JSON3.write(response_body)
                headers = ["Content-Type" => "application/json; charset=utf-8"]
                return HTTP.Response(200, headers , body=body)
            end 
        catch error
            if !suppressErrors
                @error "ERROR: " exception=(error, catch_backtrace())
            end
            return HTTP.Response(500, "The Server encountered a problem")
        end
    end

    ### Request helper functions ###

    function queryparams(req::HTTP.Request)
        local uri = HTTP.URI(req.target)
        return HTTP.queryparams(uri.query)
    end

    function html(content::String; status = 200, headers = ["Content-Type" => "text/html; charset=utf-8"])
        return HTTP.Response(status, headers, body = content)
    end

    ### Helper functions used to parse the body of each Request

    function text(req::HTTP.Request)
        body = IOBuffer(HTTP.payload(req))
        return eof(body) ? nothing : read(seekstart(body), String)
    end

    function binary(req::HTTP.Request)
        body = IOBuffer(HTTP.payload(req))
        return eof(body) ? nothing : readavailable(body)
    end

    function json(req::HTTP.Request)
        body = IOBuffer(HTTP.payload(req))
        return eof(body) ? nothing : JSON3.read(body)
    end

    function json(req::HTTP.Request, classtype)
        body = IOBuffer(HTTP.payload(req))
        return eof(body) ? nothing : JSON3.read(body, classtype)    
    end


    ### Helper functions used to parse the body of each Response

    function text(response::HTTP.Response)
        return String(response.body)
    end

    function json(response::HTTP.Response)
        return JSON3.read(String(response.body))
    end

    function json(response::HTTP.Response, classtype)
        return JSON3.read(String(response.body), classtype)
    end

    ### Core Macros ###

    macro get(path, func)
        quote 
            @route $path ["GET"] $(esc(func))
        end
    end

    macro post(path, func)
        quote 
            @route $path ["POST"] $(esc(func))
        end
    end

    macro put(path, func)
        quote 
            @route $path ["PUT"] $(esc(func))
        end
    end

    macro patch(path, func)
        quote 
            @route $path ["PATCH"] $(esc(func))
        end
    end

    macro delete(path, func)
        quote 
            @route $path ["DELETE"] $(esc(func))
        end
    end
    
    macro route(path, methods, func)
        quote 
            local func = $(esc(func))
            local path = $path
            for method in eval($methods)
                eval(:(@register $method $path $func))
            end
        end  
    end

    macro staticfiles(folder::String, mountdir::String="static")
    
        # collect all files inside the given 
        target_files::Array{String} = []
        for (root, _, files) in walkdir(folder)
            for file in files
                push!(target_files, joinpath(root, file))
            end
        end
        
        # mount all files inside the /static folder (or user defined mount point)
        quote 
            local directory = $mountdir
            for filepath in $target_files
                mountpath = "/$directory/$filepath"
                eval(
                    quote 
                        @get $mountpath function (req)
                            content_type = FileUtil.getfilecontenttype($filepath)
                            headers = ["Content-Type" => "$content_type; charset=utf-8"]
                            body = FileUtil.file($filepath)
                            return HTTP.Response(200, headers , body=body) 
                        end
                    end
                )
            end
        end
        
    end
     
    macro register(httpmethod, path, func)

        local variableRegex = r"{[a-zA-Z0-9_]+}"
        local hasBraces = r"({)|(})"

        # determine if we have parameters defined in our path
        local hasPathParams = contains(path, variableRegex)
        local cleanpath = hasPathParams ? replace(path, variableRegex => "*") : path 
      
        # track which index the params are located in
        local positions = []
        for (index, value) in enumerate(HTTP.URIs.splitpath(path)) 
            if contains(value, hasBraces)
                push!(positions, index)
            end
        end
        
        local hasPositions = !isempty(positions)
        local lower_bound = hasPositions ? first(positions) : 0
        local upper_bound = hasPositions ? last(positions) : 0

        # get the functions high-level signature
        local method = first(methods(func))
        # extract the fieldtypes 
        local fields = [x for x in fieldtypes(method.sig)]
        local numfields = fieldcount(method.sig)

        # extract the type of each argument 
        local pathtypes = splice!(Array(fields), 3:numfields)

        local handlerequest = quote 
            local action = $(esc(func))
            function (req, suppressErrors)
                try 
                    # don't pass any args if the function takes none
                    if $numfields == 1 
                        action()
                    # if endpoint has path parameters, make sure the attached function accepts them
                    elseif $hasPathParams & $hasPositions
                        path_values = splice!(HTTP.URIs.splitpath(req.target), $lower_bound:$upper_bound)
                        pathParams = [type == Any ? value : parse(type, value) for (type, value) in zip($pathtypes, path_values)]   
                        action(req, pathParams...)
                    else 
                        action(req)
                    end
                catch error
                    if !suppressErrors
                        @error "ERROR: " exception=(error, catch_backtrace())
                    end
                    return HTTP.Response(500, "The Server encountered a problem")
                end
            end
        end

        quote 
            HTTP.@register(ROUTER, $httpmethod, $cleanpath, $handlerequest)
        end
    end

end