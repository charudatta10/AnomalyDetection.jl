using AnomalyDetection,EvalCurves, DataFrames
include("../eval.jl")
using Combinatorics, ProgressMeter

function idxpairs(N)
    ps = []
    for x in combinations(1:N,2)
        push!(ps,x)
    end
    return ps 
end

scramble(x) = x[sample(1:length(x),length(x),replace=false)]
subfeatures(data, inds) = Dataset(data.data[inds,:], data.labels)

function knnscore(trdata, tstdata)
    # only use nonanomalous data for training
    trx = trdata.data[:,trdata.labels.==0]
    kvec = [1,3,5,11,27]
    aucvec = []
    for k in kvec
        # construct and fit the model
        model = AnomalyDetection.kNN(k, 0.1)
        AnomalyDetection.fit!(model, trx)
        # get auc on testing data
        as = AnomalyDetection.anomalyscore(model,tstdata.data)
        auc = EvalCurves.auc(EvalCurves.roccurve(as,tstdata.labels)...)
        push!(aucvec, auc)
    end
    mx = findmax(aucvec)
    return mx[1], kvec[mx[2]]
end

function vaescore(trdata, tstdata)
    # only use nonanomalous data for training
    trx = trdata.data[:,trdata.labels.==0]
    M,N = size(trx)
    model = AnomalyDetection.VAE([M,4,8,4,2],[1,4,8,4,M])
    AnomalyDetection.fit!(model,trx,min(N,256),
        iterations = 10000,
        cbit=500, 
        lambda = 0.0001,
        verb = false
    )
    as = AnomalyDetection.anomalyscore(model,tstdata.data,10)
    auc = EvalCurves.auc(EvalCurves.roccurve(as,tstdata.labels)...)
    return auc
end

function getdata(dataset,alldata=true)
	if alldata
		return AnomalyDetection.getdata(dataset, seed = 518)
	else
		if dataset_name in ["madelon", "gisette", "abalone", "haberman", "letter-recognition",
			"isolet", "multiple-features", "statlog-shuttle"]
			difficulty = "medium"
		elseif dataset_name in ["vertebral-column"]
			difficulty = "hard"
		else
			difficulty = "easy"
		end
		return AnomalyDetection.getdata(dataset, 0.8, difficulty, seed = 518)
	end
end

function scorefeatures(dataset, maxtries = 10, alldata = true)
    # dataframe to store results
    resdf = DataFrame(
        f1 = Int[],
        f2 = Int[],
        vae = Float64[],
        knn = Float64[],
        k = Int[]
        )
    
    # get all the data
    data = getdata(dataset, alldata)
    M,N = size(data[1].data)
    
    # create pairs
    ipairs = idxpairs(M)
    ipairs = scramble(ipairs)
    
    # progress
    imax = min(length(ipairs),maxtries)
    p = Progress(imax)
    
    for i in 1:imax
        pair = pop!(ipairs)
        trdata = subfeatures(data[1], pair)
        tstdata = subfeatures(data[2], pair)
        
        # get the kNN scores
        ks, k = knnscore(trdata,tstdata)
        # get VAE score
        vs = vaescore(trdata,tstdata)
        
        push!(resdf, [pair[1], pair[2], vs, ks, k])
        next!(p)
    end
    return resdf
end