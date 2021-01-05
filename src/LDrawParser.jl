module LDrawParser

using LightGraphs
using GeometryBasics
using Parameters

export
    get_part_library_dir,
    set_part_library_dir!,
    find_part_file

global PART_LIBRARY_DIR = "/scratch/ldraw_parts_library/ldraw/"
get_part_library_dir() = deepcopy(PART_LIBRARY_DIR)
function set_part_library_dir!(path)
    PART_LIBRARY_DIR = path
end

function find_part_file(name,library=get_part_library_dir())
    directories = [joinpath(library,"p"),joinpath(library,"parts")]
    for d in directories
        p = joinpath(d,name)
        if isfile(p)
            return p
        end
        p = joinpath(d,lowercase(name))
        if isfile(p)
            return p
        end
    end
    println("Part file ",name," not found in library at ",library)
end

# Each line of an LDraw file begins with a number 0-5
const META          = 0
const SUB_FILE_REF  = 1
const LINE          = 2
const TRIANGLE      = 3
const QUADRILATERAL = 4
const OPTIONAL      = 5

function parse_line(line)
    if Base.Sys.isunix()
        line = replace(line,"\\"=>"/") # switch from Windows directory delimiters to Unix
    end
    split_line = split(line)
    return split_line
end

const Point3D   = Point{3,Float64}

"""
    NgonElement

Represents geometry from an LDraw file
"""
struct NgonElement{E}
    color::Int
    geom::E
end

"""
    OptionalLineElement

Represents optional line geometry from an LDraw file
"""
struct OptionalLineElement
    color::Int
    line::Line
    control_pts::Line
end

"""
    SubFileRef

Represents a sub-file reference from an LDraw file. Encodes the placement of a
part or submodel.
"""
struct SubFileRef
    color::Int
    pos::Point3D
    rot::Mat{3,3,Float64}
    file::String
end

"""
    BuildingStep

Represents a sequence of part placements that make up a building step in a LDraw
file.
"""
struct BuildingStep
    lines::Vector{SubFileRef}
    BuildingStep() = new(Vector{SubFileRef}())
end
Base.push!(step::BuildingStep,ref::SubFileRef) = push!(step.lines,ref)

"""
    SubModelPlan

Represents the sequence of building steps that make up a sub model in an LDraw
file
"""
struct SubModelPlan
    name::String
    steps::Vector{BuildingStep}
    SubModelPlan(name::String) = new(
        name,
        Vector{BuildingStep}([BuildingStep()])
        )
end

export
    MPDModel,
    parse_ldraw_file!,
    parse_ldraw_file


const Quadrilateral{Dim,T} = GeometryBasics.Ngon{Dim,T,4,Point{Dim,T}}
mutable struct Toggle
    status::Bool
end

"""
    DATModel

Encodes the raw geometry of a LDraw part stored in a .dat file. It is possible
to avoid populating the geometry fields, which is useful for large models or
models that use parts from the LDraw library.
"""
struct DATModel
    name::String
    line_geometry::Vector{NgonElement{Line{3,Float64}}}
    triangle_geometry::Vector{NgonElement{Triangle{3,Float64}}}
    quadrilateral_geometry::Vector{NgonElement{Quadrilateral{3,Float64}}}
    optional_line_geometry::Vector{OptionalLineElement}
    subfiles::Vector{SubFileRef} # points to other DATModels
    populated::Toggle
    DATModel(name::String) = new(
        name,
        Vector{NgonElement{Line{3,Float64}}}(),
        Vector{NgonElement{Triangle{3,Float64}}}(),
        Vector{NgonElement{Quadrilateral{3,Float64}}}(),
        Vector{OptionalLineElement}(),
        Vector{String}(),
        Toggle(false)
    )
end

# """
#     LDRModel
#
# Encodes the LDraw information stored in a LDR file.
# """
# struct LDRModel
#     id
#     name
#     steps::Vector{BuildingStep}
#     parts::Vector{DATModel}
# end


"""
    MPDModel

The MPD model stores the information contained in a .mpd or .ldr file. This
includes a submodel tree (stored implicitly in a dictionary that maps model_name
to SubModelPlan) and a part list. The first model in MPDModel.models is the main
model. All the following are submodels of that model and/or each other.
"""
struct MPDModel
    models::Dict{String,SubModelPlan} # each file is a list of steps
    parts::Dict{String,DATModel}
    # steps
    MPDModel() = new(
        Dict{String,SubModelPlan}(),
        Dict{String,DATModel}()
    )
end

@with_kw struct MPDModelState
    active_model::String = ""
    active_part::String = ""
end
update_state(state::MPDModelState) = MPDModelState(state) # TODO deal with single step macro commands, etc.
function active_building_step(submodel::SubModelPlan,state)
    @assert !isempty(submodel.steps)
    active_step = submodel.steps[end]
end
function active_submodel(model::MPDModel,state)
    @assert !isempty(model.models)
    return model.models[state.active_model]
end
function set_new_active_model!(model::MPDModel,state,name)
    @assert !haskey(model.models,name)
    model.models[name] = SubModelPlan(name)
    return MPDModelState(state,active_model=name)
end
function active_building_step(model::MPDModel,state)
    active_model = active_submodel(model,state)
    return active_building_step(active_model,state)
end
function set_new_active_building_step!(model::SubModelPlan)
    push!(model.steps,BuildingStep())
    return model
end
function set_new_active_building_step!(model::MPDModel,state)
    active_model = active_submodel(model,state)
    set_new_active_building_step!(active_model)
    return model
end
function active_part(model::MPDModel,state)
    @assert !isempty(model.parts)
    return model.parts[state.active_part]
end
function set_new_active_part!(model::MPDModel,state,name)
    @assert !haskey(model.parts,name)
    model.parts[name] = DATModel(name)
    println("Active part = $name")
    return MPDModelState(state,active_part=name)
end
function add_sub_file_placement!(model::MPDModel,state,ref)
    if state.active_model != ""
        push!(active_building_step(model,state),ref)
    end
    if !haskey(model.parts,ref.file)
        model.parts[ref.file] = DATModel(ref.file)
    end
    return state
end

"""
    parse_ldraw_file!

Args:
    - model
    - filename or IO
"""
function parse_ldraw_file!(model,io,state = MPDModelState())
    # state = MPDModelState()
    for line in eachline(io)
        try
            # @show line
            if length(line) == 0
                continue
            end
            # split_line = split(line," ")
            split_line = parse_line(line)
            if isempty(split_line[1])
                continue
            end
            code = parse(Int,split_line[1])
            if code == META
                state = read_meta_line!(model,state,split_line)
            elseif code == SUB_FILE_REF
                state = read_sub_file_ref!(model,state,split_line)
            elseif code == LINE
                state = read_line!(model,state,split_line)
            elseif code == TRIANGLE
                state = read_triangle!(model,state,split_line)
            elseif code == QUADRILATERAL
                state = read_quadrilateral!(model,state,split_line)
            elseif code == OPTIONAL
                state = read_optional_line!(model,state,split_line)
            end
        catch e
            @show state
            rethrow(e)
        end
    end
    return model
end
function parse_ldraw_file!(model,filename::String,args...)
    open(filename,"r") do io
        parse_ldraw_file!(model,io,args...)
    end
end

parse_ldraw_file(io) = parse_ldraw_file!(MPDModel(),io)
parse_color(c) = parse(Int,c)

export populate_part_geometry!

"""
    populate_part_geometry!(model,part_keys=Set(collect(keys(model.parts))))

Populate `model` with geometry (from ".dat" files only) of all parts that belong
to model and whose names are included in `part_keys`.
"""
function populate_part_geometry!(model,part_keys=Set(collect(keys(model.parts))))
    excluded_keys = setdiff(Set(collect(keys(model.parts))), part_keys)
    explored = Set{String}()
    while !isempty(part_keys)
        while !isempty(part_keys)
            partfile = pop!(part_keys)
            populate_part_geometry!(model,partfile)
            push!(explored,partfile)
        end
        part_keys = setdiff(Set(collect(keys(model.parts))),union(explored,excluded_keys))
    end
    return model
end
function populate_part_geometry!(model,partfile::String)
    state = LDrawParser.MPDModelState(active_part=partfile)
    if splitext(partfile)[end] == ".dat"
        println("PART FILE ",partfile)
        part = model.parts[partfile]
        if part.populated.status
            println("Geometry already populated for part ",partfile)
            return false
        else
            parse_ldraw_file!(model,find_part_file(partfile),state)
            part.populated.status = true
            return true
        end
    end
end

"""
    read_meta_line(model,state,line)

Modifies the model and parser_state based on a META command. For example, the
FILE meta command indicates the beginning of a new file, so this creates a new
active model into which subsequent building steps will be placed.
The STEP meta command indicates the end of the current step, which prompts the
parser to close the current build step and begin a new one.
"""
function read_meta_line!(model,state,line)
    @assert parse(Int,line[1]) == META
    if length(line) < 2
        # usually this means the end of the file
        # println("Returning because length(line) < 2")
        return state
    end
    cmd = line[2]
    if cmd == "FILE"
        filename = join(line[3:end]," ")
        ext = splitext(filename)[2]
        if ext == ".dat"
            state = set_new_active_part!(model,state,filename)
        elseif ext == ".mpd" || ext == ".ldr"
            state = set_new_active_model!(model,state,filename)
        end
    elseif cmd == "STEP"
        set_new_active_building_step!(model,state)
    else
        # TODO Handle other META commands, especially BFC
    end
    return state
end

"""
    read_sub_file_ref

Receives a SUB_FILE_REF line (with the leading SUB_FILE_REF id stripped)
"""
function read_sub_file_ref!(model,state,line)
    @assert parse(Int,line[1]) == SUB_FILE_REF
    @assert length(line) >= 15 "$line"
    color = parse_color(line[2])
    # coordinate of part
    x,y,z = parse.(Float64,line[3:5])
    # rotation of part
    rot_mat = collect(transpose(reshape(parse.(Float64,line[6:14]),3,3)))
    file = join(line[15:end]," ")
    # TODO add a line struct to the model
    ref = SubFileRef(
        color,
        Point3D(x,y,z),
        Mat{3,3,Float64}(rot_mat),
        file
    )
    add_sub_file_placement!(model,state,ref)
    # push!(model.sub_file_refs,ref)
    return state
end

"""
    read_line!

For reading lines of type LINE
"""
function read_line!(model,state,line)
    @assert parse(Int,line[1]) == LINE
    @assert length(line) == 8 "$line"
    color = parse_color(line[2])
    p1 = Point3D(parse.(Float64,line[3:5]))
    p2 = Point3D(parse.(Float64,line[6:8]))
    # add to model
    push!(
        active_part(model,state).line_geometry,
        NgonElement(color,Line(p1,p2))
        )
    return state
end

"""
    read_triangle!

For reading lines of type TRIANGLE
"""
function read_triangle!(model,state,line)
    @assert parse(Int,line[1]) == TRIANGLE
    @assert length(line) == 11 "$line"
    color = parse_color(line[2])
    p1 = Point3D(parse.(Float64,line[3:5]))
    p2 = Point3D(parse.(Float64,line[6:8]))
    p3 = Point3D(parse.(Float64,line[9:11]))
    # add to model
    push!(
        active_part(model,state).triangle_geometry,
        NgonElement(color,Triangle(p1,p2,p3))
        )
    return state
end

"""
    read_quadrilateral!

For reading lines of type QUADRILATERAL
"""
function read_quadrilateral!(model,state,line)
    @assert parse(Int,line[1]) == QUADRILATERAL
    @assert length(line) == 14 "$line"
    color = parse_color(line[2])
    p1 = Point3D(parse.(Float64,line[3:5]))
    p2 = Point3D(parse.(Float64,line[6:8]))
    p3 = Point3D(parse.(Float64,line[9:11]))
    p4 = Point3D(parse.(Float64,line[12:14]))
    # add to model
    push!(
        active_part(model,state).quadrilateral_geometry,
        NgonElement(color,GeometryBasics.Quadrilateral(p1,p2,p3,p4))
        )
    return state
end

"""
    read_optional_line!

For reading lines of type OPTIONAL
"""
function read_optional_line!(model,state,line)
    @assert parse(Int,line[1]) == OPTIONAL
    @assert length(line) == 14
    color = parse_color(line[2])
    p1 = Point3D(parse.(Float64,line[3:5]))
    p2 = Point3D(parse.(Float64,line[6:8]))
    p3 = Point3D(parse.(Float64,line[9:11]))
    p4 = Point3D(parse.(Float64,line[12:14]))
    # add to model
    push!(
        active_part(model,state).optional_line_geometry,
        OptionalLineElement(
            color,
            Line(p1,p2),
            Line(p3,p4)
        ))
    return state
end


end
