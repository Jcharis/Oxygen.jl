module AutoDoc 
using HTTP
using Dates
using DataStructures
using Reexport
using RelocatableFolders

using ..Constants
using ..Util
using ..Core: Context, Documenation
using ..Types: TaggedRoute

export registerschema, 
    swaggerhtml, redochtml, getschemapath, configdocs, mergeschema, setschema, 
    getrepeatasks, hasmiddleware, compose, resetstatevariables

const SWAGGER_VERSION   = "swagger@5.7.2"
const REDOC_VERSION     = "redoc@2.1.2"


"""
    mergeschema(route::String, customschema::Dict)

Merge the schema of a specific route
"""
function mergeschema(schema::Dict, route::String, customschema::Dict)
    schema["paths"][route] = recursive_merge(get(schema["paths"], route, Dict()), customschema)
end


"""
    mergeschema(customschema::Dict)

Merge the top-level autogenerated schema with a custom schema
"""
function mergeschema(schema::Dict, customschema::Dict)
    updated_schema = recursive_merge(schema, customschema)
    merge!(schema, updated_schema)    
end


"""
returns true if we have any special middleware (router or route specific)
"""
function hasmiddleware(custommiddleware::Dict{String, Tuple})::Bool 
    return !isempty(custommiddleware)
end


"""
This function dynamically determines which middleware functions to apply to a request at runtime. 
If router or route specific middleware is defined, then it's used instead of the globally defined
middleware. 
"""
function compose(router, appmiddleware, custommiddleware)
    return function(handler)
        return function(req::HTTP.Request)
            innerhandler, path, params = HTTP.Handlers.gethandler(router, req)
            # Check if the current request matches one of our predefined routes 
            if innerhandler !== nothing
                
                # always initialize with the next handler function
                layers::Vector{Function} = [ handler ] 

                # lookup the middleware for this path
                routermiddleware, routemiddleware = get(custommiddleware, "$(req.method)|$path", (nothing, nothing))

                # calculate the checks ahead of time
                hasrouter = !isnothing(routermiddleware) 
                hasroute = !isnothing(routemiddleware) 

                # case 1: no middleware is defined at any level -> use global middleware
                if !hasrouter && !hasroute
                    append!(layers, reverse(appmiddleware))

                # case 2: if route level is empty -> don't add any middleware
                elseif hasroute && isempty(routemiddleware)  
                    return req |> reduce(|>, layers)

                # case 3: if router level is empty -> only register route level middleware
                elseif hasrouter && isempty(routermiddleware)
                    hasroute && append!(layers, reverse(routemiddleware))

                # case 4: router & route level is defined -> combine global, router, and route middleware 
                elseif hasrouter && hasroute
                    append!(layers, reverse([appmiddleware..., routermiddleware..., routemiddleware...]))

                # case 5: only router level is defined ->  combine global and router middleware 
                elseif hasrouter && !hasroute
                    append!(layers, reverse([appmiddleware..., routermiddleware...]))

                # case 6: only route level is defined -> combine global + route level middleware
                elseif !hasrouter && hasroute
                    append!(layers, reverse([appmiddleware..., routemiddleware...]))
                end
                
                # combine all the middleware functions together 
                return req |> reduce(|>, layers)
            end
            return handler(req)
        end
    end
end

"""
This functions assists registering routes with a specific prefix.
You can optionally assign tags either at the prefix and/or route level which
are used to group and organize the autogenerated documentation
"""
#function router(taggedroutes::Dict{String, TaggedRoute}, custommiddleware::Dict{String, Tuple}, repeattasks::Vector, prefix::String = ""; 
function router(ctx::Context, prefix::String = ""; 
                tags::Vector{String} = Vector{String}(), 
                middleware::Union{Nothing, Vector} = nothing, 
                interval::Union{Real, Nothing} = nothing,
                cron::Union{String, Nothing} = nothing)

    return createrouter(ctx, prefix, tags, middleware, interval, cron)
end

function createrouter(ctx::Context, prefix::String, 
                    routertags::Vector{String}, 
                    routermiddleware::Union{Nothing, Vector}, 
                    routerinterval::Union{Real, Nothing},
                    routercron::Union{String, Nothing} = nothing)

    # appends a "/" character to the given string if doesn't have one. 
    function fixpath(path::String)
        path = String(strip(path))
        if !isnothing(path) && !isempty(path) && path !== "/"
            return startswith(path, "/") ? path : "/$path"
        end
        return ""
    end

    # This function takes input from the user next to the request handler
    return function(path = nothing; 
                    tags::Vector{String} = Vector{String}(), 
                    middleware::Union{Nothing, Vector} = nothing, 
                    interval::Union{Real, Nothing} = routerinterval,
                    cron::Union{String, Nothing} = routercron)

        # this is called inside the @register macro (only it knows the exact httpmethod associated with each path)
        return function(httpmethod::String)
            
            """
            This scenario can happen when the user passes a router object directly like so: 

            @get router("/math/power/{a}/{b}") function (req::HTTP.Request, a::Float64, b::Float64)
                return a ^ b
            end

            Under normal circumstances, the function returned by the router call is used when registering routes. 
            However, in this specific case, the call to router returns a higher-order function (HOF) that's nested one 
            layer deeper than expected.

            Due to the way we call these functions to derive the path for the currently registered route, 
            the path argument can sometimes be mistakenly set to the HTTP method (e.g., "GET", "POST"). 
            This can lead to the path getting concatenated with the HTTP method string.

            To account for this specific use case, we've added a check in the inner function to verify whether 
            path matches the current passed in httpmethod. If it does, we assume that path has been incorrectly 
            set to the HTTP method, and we update path to use the router prefix instead.
            """
            if path === httpmethod
                path = prefix
            else 
                # combine the current routers prefix with this specfic path 
                path = !isnothing(path) ? "$(fixpath(prefix))$(fixpath(path))" : fixpath(prefix)
            end

            if !(isnothing(routermiddleware) && isnothing(middleware))
                # add both router & route-sepecific middleware
                ctx.service.custommiddleware["$httpmethod|$path"] = (routermiddleware, middleware)
            end
            
            # register interval for this route 
            if !isnothing(interval) && interval >= 0.0
                task = (path, httpmethod, interval)
                push!(ctx.tasks.repeattasks, task)
            end

            # register cron expression for this route 
            if !isnothing(cron) && !isempty(cron)
                task = (path, httpmethod, cron)
                push!(ctx.cron.job_definitions, task)                 
            end

            combinedtags = [tags..., routertags...]

            # register tags
            if !haskey(ctx.docs.taggedroutes, path)
                ctx.docs.taggedroutes[path] = TaggedRoute([httpmethod], combinedtags)
            else 
                combinedmethods = vcat(httpmethod, ctx.docs.taggedroutes[path].httpmethods)
                ctx.docs.taggedroutes[path] = TaggedRoute(combinedmethods, combinedtags)
            end

            #return path 
            return path
        end
    end
end


"""
Returns the openapi equivalent of each Julia type
"""
function gettype(type::Type) :: String
    if type <: Bool
        return "boolean"
    elseif type <: AbstractFloat
        return "number"
    elseif type <: Integer 
        return "integer"
    elseif type <: AbstractVector
        return "array"
    elseif type <: String || type == Date || type == DateTime
        return "string"
    elseif isstructtype(type)
        return "object"
    else 
        return "string"
    end
end

"""
Returns the specific format type for a given parameter
ex.) DateTime(2022,1,1) => "date-time"
"""
function getformat(type::Type) :: Union{String,Nothing}
    if type <: AbstractFloat
        if type == Float32
            return "float"
        elseif type == Float64
            return "double"
        end
    elseif type <: Integer 
        if type == Int32
            return "int32"
        elseif type == Int64
            return "int64"
        end
    elseif type == Date 
        return "date"
    elseif type == DateTime
        return "date-time"
    end
    return nothing
end



"""
Used to generate & register schema related for a specific endpoint 
"""
function registerschema(docs::Documenation, path::String, httpmethod::String, parameters, returntype::Array)

    params = []
    for (name, type) in parameters
        format = getformat(type)
        param = Dict( 
            "in" => "path",
            "name" => "$name", 
            "required" => "true",
            "schema" => Dict(
                "type" => gettype(type)
            )
        )
        if !isnothing(format)
            param["schema"]["format"] = format
        end
        push!(params, param)
    end

    # lookup if this route has any registered tags
    if haskey(docs.taggedroutes, path) && httpmethod in docs.taggedroutes[path].httpmethods
        tags = docs.taggedroutes[path].tags 
    else 
        tags = []
    end

    route = Dict(
        "$(lowercase(httpmethod))" => Dict(
            "tags" => tags,
            "parameters" => params,
            "responses" => Dict(
                "200" => Dict("description" => "200 response"),
                "500" => Dict("description" => "500 Server encountered a problem")
            )
        )
    )

    # Add a request body to the route if it's a POST, PUT, or PATCH request
    if httpmethod in ["POST", "PUT", "PATCH"]
        route[lowercase(httpmethod)]["requestBody"] = Dict(
            "required" => false,
            "content" => OrderedDict(
                "application/json" => Dict(
                    "schema" => Dict(
                        "type" => "object"
                    )
                ),
                "application/xml" => Dict(
                    "schema" => Dict(
                        "type" => "object"
                    )
                ),
                "text/plain" => Dict(
                    "schema" => Dict(
                        "type" => "string"
                    )
                ),
                "multipart/form-data" => Dict(
                    "schema" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "file" => Dict(
                                "type" => "string",
                                "format" => "binary"
                            )
                        ),
                        "required" => ["file"]
                    )
                )
            )
        )
    end

    # remove any special regex patterns from the path before adding this path to the schema
    cleanedpath = replace(path, r"(?=:)(.*?)(?=}/)" => "")
    mergeschema(docs.schema, cleanedpath, route)
end

"""
Read in a static file from the /data folder
"""
function readstaticfile(filepath::String) :: String 
    path = joinpath(DATA_PATH, filepath)
    return read(path, String)
end

function redochtml(schemapath::String) :: HTTP.Response
    redocjs = readstaticfile("$REDOC_VERSION/redoc.standalone.js")

    html("""
    <!DOCTYPE html>
    <html lang="en">
    
        <head>
            <title>Docs</title>
            <meta charset="utf-8"/>
            <meta name="description" content="Docs" />
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link href="https://fonts.googleapis.com/css?family=Montserrat:300,400,700|Roboto:300,400,700" rel="stylesheet">
        </head>
        
        <body>
            <redoc spec-url="$schemapath"></redoc>
            <script>$redocjs</script>
        </body>
    
    </html>
    """)
end

"""
Return HTML page to render the autogenerated docs
"""
function swaggerhtml(schemapath::String) :: HTTP.Response

    # load static content files
    swaggerjs = readstaticfile("$SWAGGER_VERSION/swagger-ui-bundle.js")
    swaggerstyles = readstaticfile("$SWAGGER_VERSION/swagger-ui.css")

    html("""
        <!DOCTYPE html>
        <html lang="en">
        
        <head>
            <title>Docs</title>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <meta name="description" content="Docs" />
            <style>$swaggerstyles</style>
        </head>
        
        <body>
            <div id="swagger-ui"></div>
            <script>$swaggerjs</script>
            <script>
                window.onload = () => {
                    window.ui = SwaggerUIBundle({
                        url: window.location.origin + "$schemapath",
                        dom_id: '#swagger-ui',
                    });
                };
            </script>
        </body>
        
        </html>
    """)
end

end
