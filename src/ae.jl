##########################
### ae NN construction ###
##########################

"""
	AE{encoder, sampler, decoder}

Flux-like structure for the basic autoencoder.
"""
struct AE{E, D}
	encoder::E
	decoder::D
end

# make the struct callable
(ae::AE)(X) = ae.decoder(ae.encoder(X))

# and make it trainable
Flux.treelike(AE)

"""
	AE(esize, dsize; [activation])

Initialize an autoencoder with given encoder size and decoder size.
esize - vector of ints specifying the width anf number of layers of the encoder
dsize - size of decoder
activation - arbitrary activation function
"""
function AE(esize::Array{Int64,1}, dsize::Array{Int64,1}; activation = Flux.relu,
		layer = Flux.Dense)
	@assert size(esize, 1) >= 3
	@assert size(dsize, 1) >= 3
	@assert esize[end] == dsize[1] 
	@assert esize[1] == dsize[end]

	# construct the encoder
	encoder = aelayerbuilder(esize, activation, layer)

	# construct the decoder
	decoder = aelayerbuilder(dsize, activation, layer)

	# finally construct the ae struct
	ae = AE(encoder, decoder)

	return ae
end

################
### training ###
################

"""
	loss(ae, X)

Reconstruction error.
"""
loss(ae::AE, X) = Flux.mse(ae(X), X)

"""
	evalloss(ae, X)

Print ae loss function values.	
"""
evalloss(ae::AE, X) = println("loss: ", Flux.Tracker.data(loss(ae, X)), "\n")

"""
	fit!(ae, X, L, [iterations, cbit, verb, rdelta, tracked])

Trains the AE.
ae - AE type object
X - data array with instances as columns
L - batchsize
iterations - number of iterations
cbit - after this # of iterations, output is printed
verb - if output should be produced
rdelta - stopping condition for reconstruction error
traindata - dict to be filled with data of individual iterations
"""
function fit!(ae::AE, X, L; iterations=1000, cbit = 200, verb = true, rdelta = Inf, traindata = nothing)
	# optimizer
	opt = ADAM(params(ae))

	# training
	for i in 1:iterations
		# sample from data
		x = X[:, sample(1:size(X,2), L, replace = false)]

		# gradient computation and update
		l = loss(ae, x)
		Flux.Tracker.back!(l)
		opt()

		# callback
		if verb && i%cbit == 0
			evalloss(ae, x)
		end

		# save actual iteration data
		if traindata != nothing
			track!(ae, traindata, x)
		end

		# if stopping condition is present
		if rdelta < Inf
			re = Flux.Tracker.data(l)[1]
			if re < rdelta
				if verb
					println("Training ended prematurely after $i iterations,\n",
						"reconstruction error $re < $rdelta")
				end
				break
			end
		end
	end	
end

"""
	track!(ae, traindata, X)

Save current progress.
"""
function track!(ae::AE, traindata, X)
	if haskey(traindata, "loss")
		push!(traindata["loss"], Flux.Tracker.data(loss(ae,X)))
	else
		traindata["loss"] = [Flux.Tracker.data(loss(ae, X))]
	end
end

#################
### ae output ###
#################

"""
	anomalyscore(ae, X)

Compute anomaly score for X.
"""
anomalyscore(ae::AE, X) = loss(ae, X)

"""
	classify(ae, x, threshold)

Classify an instance x using reconstruction error and threshold.
"""
classify(ae::AE, x, threshold) = (anomalyscore(ae, x) > threshold)? 1 : 0
classify(ae::AE, x::Array{Float,1}, threshold) = (anomalyscore(ae, x) > threshold)? 1 : 0
classify(ae::AE, X::Array{Float,2}, threshold) = reshape(mapslices(y -> classify(ae, y, threshold), X, 1), size(X,2))

"""
	getthreshold(ae, x, contamination, [Beta])

Compute threshold for AE classification based on known contamination level.
"""
function getthreshold(ae::AE, x, contamination; Beta = 1.0)
	N = size(x, 2)
	# get reconstruction errors
	xerr  = mapslices(y -> loss(ae, y), x, 1)
	# create ordinary array from the tracked array
	xerr = reshape([Flux.Tracker.data(e)[1] for e in xerr], N)
	# sort it
	xerr = sort(xerr)
	aN = max(Int(floor(N*contamination)),1) # number of contaminated samples
	# get the threshold - could this be done more efficiently?
	return Beta*xerr[end-aN] + (1-Beta)xerr[end-aN+1]
end

#############################################################################
### A SK-learn like model based on AE with the same methods and some new. ###
#############################################################################

""" 
Struct to be used as scikitlearn-like model with fit and predict methods.
"""
mutable struct AEmodel
	ae::AE
	L::Int
	threshold::Real
	contamination::Real
	iterations::Int
	cbit::Real
	verbfit::Bool
	rdelta::Real
	Beta::Float
	traindata
end

"""
	AEmodel(esize, dsize, L, threshold, contamination, iteration, cbit, 
	[activation, rdelta, Beta, tracked])

Initialize an autoencoder model with given parameters.

esize - encoder architecture
dsize - decoder architecture
L - batchsize
threshold - anomaly score threshold for classification, is set automatically using contamination during fit
contamination - percentage of anomalous samples in all data for automatic threshold computation
iterations - number of training iterations
cbit - current training progress is printed every cbit iterations
verbfit - is progress printed?
activation [Flux.relu] - activation function
rdelta [Inf] - training stops if reconstruction error is smaller than rdelta
Beta [1.0] - how tight around normal data is the automatically computed threshold
tracked [false] - is training progress (losses) stored?
"""
function AEmodel(esize::Array{Int64,1}, dsize::Array{Int64,1},
	L::Int, threshold::Real, contamination::Real, iterations::Int, 
	cbit::Real, verbfit::Bool; activation = Flux.relu, rdelta = Inf, Beta = 1.0,
	tracked = false)
	# construct the AE object
	ae = AE(esize, dsize, activation = activation)
	(tracked)? traindata = Dict{Any, Any}() : traindata = nothing
	model = AEmodel(ae, L, threshold, contamination, iterations, cbit, verbfit, rdelta, 
		Beta, traindata)
	return model
end

# reimplement some methods of AE
(model::AEmodel)(x) = model.ae(x)   
loss(model::AEmodel, X) = loss(model.ae, X)
evalloss(model::AEmodel, X) = evalloss(model.ae, X)
anomalyscore(model::AEmodel, X) = anomalyscore(model.ae, X)
classify(model::AEmodel, x) = classify(model.ae, x, model.threshold)
getthreshold(model::AEmodel, x) = getthreshold(model.ae, x, model.contamination, Beta = model.Beta)

"""
	setthreshold!(model::AEmodel, X)

Set model classification threshold based on given contamination rate.
"""
function setthreshold!(model::AEmodel, X)
	model.threshold = getthreshold(model, X)
end

"""
	fit!(model::AEmodel, X, Y)

Fit the AE model, instances are columns of X.	
"""
function fit!(model::AEmodel, X, Y) 
	# train the NN only on normal samples
	nX = X[:, Y.==0]

	# train
	fit!(model.ae, nX, model.L, iterations = model.iterations, 
	cbit = model.cbit, verb = model.verbfit, rdelta = model.rdelta,
	traindata = model.traindata)

	# now set the threshold using contamination rate
	model.contamination = size(Y[Y.==1],1)/size(Y[Y.==0],1)
	setthreshold!(model, X)
end

"""
	predict(model::AEmodel, X)

Based on known contamination level, compute threshold and classify instances in X.
"""
function predict(model::AEmodel, X)	
	return classify(model, X)
end
