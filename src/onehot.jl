import Adapt
import .CUDA

struct OneHotArray{T<:Integer, L, N, var"N+1", I<:Union{T, AbstractArray{T, N}}} <: AbstractArray{Bool, var"N+1"}
  indices::I
end
OneHotArray{T, L, N, I}(indices) where {T, L, N, I} = OneHotArray{T, L, N, N+1, I}(indices)
OneHotArray(indices::T, L::Integer) where {T<:Integer} = OneHotArray{T, L, 0, T}(indices)
OneHotArray(indices::AbstractArray{T, N}, L::Integer) where {T, N} = OneHotArray{T, L, N, typeof(indices)}(indices)

_indices(x::OneHotArray) = x.indices
_indices(x::Base.ReshapedArray{<:Any, <:Any, <:OneHotArray}) =
  reshape(parent(x).indices, x.dims[2:end])

const OneHotVector{T, L} = OneHotArray{T, L, 0, 1, T}
const OneHotMatrix{T, L, I} = OneHotArray{T, L, 1, 2, I}

OneHotVector(idx, L) = OneHotArray(idx, L)
OneHotMatrix(indices, L) = OneHotArray(indices, L)

# use this type so reshaped arrays hit fast paths
# e.g. argmax
const OneHotLike{T, L, N, var"N+1", I} =
  Union{OneHotArray{T, L, N, var"N+1", I},
        Base.ReshapedArray{Bool, var"N+1", <:OneHotArray{T, L}}}

# when reshaping a OneHotArray and first(dims) != L
# convert the parent array to Array{Bool}
# so that the ReshapedArray does not hit fast paths
function Base.ReshapedArray(parent::OneHotArray{<:Any, L}, dims::NTuple{N,Int}, mi) where {L, N}
  parent = (first(dims) != L) ? convert(_onehot_bool_type(parent), parent) : parent
  
  Base.ReshapedArray{Bool,N,typeof(parent),typeof(mi)}(parent, dims, mi)
end

Base.size(x::OneHotArray{<:Any, L}) where L = (Int(L), size(x.indices)...)

_onehotindex(x, i) = (x == i)

Base.getindex(x::OneHotVector, i::Integer) = _onehotindex(x.indices, i)
Base.getindex(x::OneHotVector{T, L}, ::Colon) where {T, L} = x

Base.getindex(x::OneHotArray, i::Integer, I...) = _onehotindex.(x.indices[I...], i)
Base.getindex(x::OneHotLike{<:Any, L}, ::Colon, I...) where L = OneHotArray(_indices(x)[I...], L)
Base.getindex(x::OneHotArray{<:Any, <:Any, <:Any, N}, ::Vararg{Colon, N}) where N = x
Base.getindex(x::OneHotArray, I::CartesianIndex{N}) where N = x[I[1], Tuple(I)[2:N]...]

_onehot_bool_type(x::OneHotLike{<:Any, <:Any, <:Any, N, <:Union{Integer, AbstractArray}}) where N = Array{Bool, N}
_onehot_bool_type(x::OneHotLike{<:Any, <:Any, <:Any, N, <:CuArray}) where N = CuArray{Bool, N}

function Base.cat(xs::OneHotLike{<:Any, L}...; dims::Int) where L
  if isone(dims)
    return cat(map(x -> convert(_onehot_bool_type(x), x), xs)...; dims = dims)
  else
    return OneHotArray(cat(_indices.(xs)...; dims = dims - 1), L)
  end
end

Base.hcat(xs::OneHotLike...) = cat(xs...; dims = 2)
Base.vcat(xs::OneHotLike...) = cat(xs...; dims = 1)

batch(xs::AbstractArray{<:OneHotVector{<:Any, L}}) where L = OneHotArray(_indices.(xs), L)

Adapt.adapt_structure(T, x::OneHotLike{<:Any, L}) where L = OneHotArray(adapt(T, _indices(x)), L)

Base.BroadcastStyle(::Type{<:OneHotLike{<:Any, <:Any, <:Any, N, <:CuArray}}) where N = CUDA.CuArrayStyle{N}()

Base.argmax(x::OneHotLike; dims = Colon()) =
  (dims == 1) ? reshape(CartesianIndex.(_indices(x), CartesianIndices(_indices(x))), 1, size(_indices(x))...) :
                argmax(convert(_onehot_bool_type(x), x); dims = dims)

"""
    onehot(l, labels[, unk])

Return a `OneHotVector` where only first occourence of `l` in `labels` is `1` and
all other elements are `0`.

If `l` is not found in labels and  `unk` is present, the function returns
`onehot(unk, labels)`; otherwise the function raises an error.

# Examples
```jldoctest
julia> Flux.onehot(:b, [:a, :b, :c])
3-element Flux.OneHotArray{UInt32,3,0,1,UInt32}:
 0
 1
 0

julia> Flux.onehot(:c, [:a, :b, :c])
3-element Flux.OneHotArray{UInt32,3,0,1,UInt32}:
 0
 0
 1
```
"""
function onehot(l, labels)
  i = something(findfirst(isequal(l), labels), 0)
  i > 0 || error("Value $l is not in labels")
  OneHotVector{UInt32, length(labels)}(i)
end

function onehot(l, labels, unk)
  i = something(findfirst(isequal(l), labels), 0)
  i > 0 || return onehot(unk, labels)
  OneHotVector{UInt32, length(labels)}(i)
end

"""
    onehotbatch(ls, labels[, unk...])

Return a `OneHotMatrix` where `k`th column of the matrix is `onehot(ls[k], labels)`.

If one of the input labels `ls` is not found in `labels` and `unk` is given,
return [`onehot(unk, labels)`](@ref) ; otherwise the function will raise an error.

# Examples
```jldoctest
julia> Flux.onehotbatch([:b, :a, :b], [:a, :b, :c])
3×3 Flux.OneHotArray{UInt32,3,1,2,Array{UInt32,1}}:
 0  1  0
 1  0  1
 0  0  0
```
"""
onehotbatch(ls, labels, unk...) = batch([onehot(l, labels, unk...) for l in ls])

"""
    onecold(y[, labels = 1:length(y)])

Inverse operations of [`onehot`](@ref).

# Examples
```jldoctest
julia> Flux.onecold([true, false, false], [:a, :b, :c])
:a

julia> Flux.onecold([0.3, 0.2, 0.5], [:a, :b, :c])
:c
```
"""
onecold(y::AbstractVector, labels = 1:length(y)) = labels[argmax(y)]
function onecold(y::AbstractArray, labels = 1:size(y, 1))
  indices = _fast_argmax(y)
  xs = isbits(labels) ? indices : collect(indices) # non-bit type cannot be handled by CUDA

  return map(xi -> labels[xi[1]], xs)
end

_fast_argmax(x::AbstractArray) = dropdims(argmax(x; dims = 1); dims = 1)
_fast_argmax(x::OneHotLike) = _indices(x)

@nograd OneHotArray, onecold, onehot, onehotbatch

function Base.:(*)(A::AbstractMatrix, B::OneHotLike{<:Any, L}) where L
  size(A, 2) == L || throw(DimensionMismatch("Matrix column must correspond with OneHot size: $(size(A, 2)) != $L"))
  return A[:, onecold(B)]
end
