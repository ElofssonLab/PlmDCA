using GaussDCA
using NLopt

immutable PlmAlg
    method::Symbol
    verbose::Bool
    epsconv::Float64
    maxit::Int
end

immutable GPlmVar
    N::Int
    M::Int
    q::Int    
    q2::Int
    lambdaJ::Float64
    lambdaH::Float64
    lambdaG::Float64
    Z::SharedArray{Int,2}
    W::SharedArray{Float64,1}
    function PlmVar(N,M,q,q2,lambdaJ, lambdaH, lambdaG, Z,W)
        sZ = SharedArray(Int,size(Z))
        sZ[:] = Z
        sW = SharedArray(Float64,size(W))
        sW[:] = W        
        new(N,M,q,q2,lambdaJ, lambdaH, lambdaG, sZ,sW)
    end
end


function gplmdca(filename::String;
                decimation::Bool=false,
                fracmax::Float64 = 0.3,
                fracdec::Float64 = 0.1,
                remove_dups::Bool = true,
                max_gap_fraction::Real = 0.9, 
                theta = :auto, 
                lambdaJ::Real=0.005, 
                lambdaH::Real=0.01,
                lambdaG::Real=0.01, 
                epsconv::Real=1.0e-5,
                maxit::Int=1000,
                verbose::Bool=true,
                method::Symbol=:LD_LBFGS)
    

    W,Z,N,M,q = ReadFasta(filename,max_gap_fraction, theta, remove_dups)

    plmalg = PlmAlg(method,verbose, epsconv ,maxit)
    plmvar = PlmVar(N,M,q,q*q,lambdaJ,lambdaH,lambdaG,Z,W)

    if !decimation       
        Jmat,pslike = MinimizePL(plmalg,plmvar) #initial minimization
        FN,_,_ = ComputeScore(Jmat, plmvar)
        score = GaussDCA.compute_ranking(FN)
    else
        reload("decimation.jl")
        decvar = DecVar(fracdec, fracmax, ones(Bool, (N-1)*q*q, N))
        FN,_,_ = ComputeScore(Jmat, plmvar)
        score = GaussDCA.compute_ranking(FN)
        Jtensor, pslike = Decimate!(plmvar, plmalg, decvar)
    end

    return score, pslike
end
    

function ComputeScore(Jmat::Array{Float64,2}, var::PlmVar)

    q = var.q
    N = var.N

    JJ=reshape(Jmat[1:end-q,:], q,q,N-1,N)
    Jtemp1=zeros( q,q,int(N*(N-1)/2))
    Jtemp2=zeros( q,q,int(N*(N-1)/2))
    l = 1

    for i=1:(N-1)
        for j=(i+1):N
            Jtemp1[:,:,l]=JJ[:,:,j-1,i]; #J_ij as estimated from from g_i.
            Jtemp2[:,:,l]=JJ[:,:,i,j]'; #J_ij as estimated from from g_j.
            l=l+1;
        end
    end
    
    Jtensor = zeros(q,q,N,N)
    l = 1
    for i = 1:N-1
        for j=i+1:N
            Jtensor[:,:,i,j] = Jtemp1[:,:,l]
            Jtensor[:,:,j,i] = Jtemp2[:,:,l]'
            l += 1
        end
    end

    ASFN = zeros(N,N)
    for i=1:N,j=1:N 
        i!=j && (ASFN[i,j] =sum(Jtensor[:,:,i,j].^2)) 
    end

    J1=zeros(q,q,int(N*(N-1)/2))
    J2=zeros(q,q,int(N*(N-1)/2))

    for l=1:int(N*(N-1)/2)
        J1[:,:,l] = Jtemp1[:,:,l]-repmat(mean(Jtemp1[:,:,l],1),q,1)-repmat(mean(Jtemp1[:,:,l],2),1,q) .+ mean(Jtemp1[:,:,l])
        J2[:,:,l] = Jtemp2[:,:,l]-repmat(mean(Jtemp2[:,:,l],1),q,1)-repmat(mean(Jtemp2[:,:,l],2),1,q) .+ mean(Jtemp2[:,:,l])
    end
    J = 0.5 * ( J1 + J2 )



    FN = zeros(Float64, N,N)
    l = 1

    for i=1:N-1
        for j=i+1:N
            FN[i,j] = vecnorm(J[:,:,l],2)
            FN[j,i] =FN[i,j]
            l+=1
        end
    end
    FN=GaussDCA.correct_APC(FN)
    return FN, ASFN, Jtensor
end

function MinimizeGPL(alg::PlmAlg, var::PlmVar)

    
    x0 = zeros(Float64, (var.N - 1) * var.q2 + var.q +  )
    vecps = SharedArray(Float64,var.N)
    Jmat = @parallel hcat for site=1:var.N #1:12
        function f(x::Vector, g::Vector)
            g === nothing && (g = zeros(Float64, length(x)))
            return PLsiteAndGrad!(x, g, site,  var)            
        end
        opt = Opt(alg.method, length(x0))

        ftol_abs!(opt, alg.epsconv)
        maxeval!(opt, alg.maxit)
        min_objective!(opt, f)
        elapstime = @elapsed  (minf, minx, ret) = optimize(opt, x0)
        alg.verbose && @printf("site = %d\t pl = %.4f\t time = %.4f\n", site, minf, elapstime)
        vecps[site] = minf
        minx
    end 
    return Jmat, sum(vecps)
end

function ReadFasta(filename::String,max_gap_fraction::Real, theta::Any, remove_dups::Bool)

    Z = GaussDCA.read_fasta_alignment(filename, max_gap_fraction)
    if remove_dups
        Z, _ = GaussDCA.remove_duplicate_seqs(Z)
    end


    N, M = size(Z)
    q = int(maximum(Z))
    
    q > 32 && error("parameter q=$q is too big (max 31 is allowed)")
    _, _, Meff, W = GaussDCA.compute_new_frequencies(Z, theta)
    W  ./= Meff  
    Zint = int( Z )
    return W, Zint,N,M,q
end

function PLsiteAndGrad!(vecJ::Array{Float64,1},  grad::Array{Float64,1}, site::Int, plmvar::PlmVar)

    LL = length(vecJ)
    q2 = plmvar.q2
    q = plmvar.q
    N = plmvar.N
    M = plmvar.M
    Z = sdata(plmvar.Z)
    W = sdata(plmvar.W)
    lambdaJ = plmvar.lambdaJ;
    lambdaH = plmvar.lambdaH;
    lambdaG = plmvar.lambdaG;
    

    for i=1:LL-q
        grad[i] = 2.0 * plmvar.lambdaJ * vecJ[i]
    end
    for i=(LL-q+1):LL
       grad[i] = 2.0 * plmvar.lambdaH * vecJ[i]
    end 

    vecene = zeros(Float64,q)
    expvecenesunorm = zeros(Float64,q)
    pseudolike = 0.0
 
    @inbounds begin 
        for a = 1:M 
            Za = Z[:,a];
            fillvecene!(vecene, vecJ,site,a, q, Z, N)        
            norm = sumexp(vecene)
            expvecenesunorm = exp(vecene .- log(norm))

            pseudolike -= W[a] * ( vecene[Z[site,a]] - log(norm) )
            offset = 0         
            for i = 1:site-1 
                @simd for s = 1:q
                    grad[ offset + s + q * ( Z[i,a] - 1 ) ] += W[a] *  expvecenesunorm[s]
                end
                grad[ offset + Z[site,a] + q * ( Z[i,a] - 1 ) ] -= W[a] 
                offset += q2 
            end
	    for i = site+1:N 
                @simd for s = 1:q
                    grad[ offset + s + q * ( Z[i,a] - 1 ) ] += W[a] *  expvecenesunorm[s]
                end
                grad[ offset + Z[site,a] + q * ( Z[i,a] - 1 ) ] -= W[a] 
                offset += q2 
            end

            @simd for s = 1:q 
                grad[ offset + s ] += W[a] *  expvecenesunorm[s] 
            end
	    grad[ offset + Z[site,a] ] -= W[a] 	
        end
    end
    pseudolike += L2norm(vecJ, plmvar)
    return pseudolike 
end

function fillvecene!(vecene::Array{Float64,1}, vecJ::Array{Float64,1},site::Int, a::Int, q::Int, sZ::DenseArray{Int,2},N::Int)
    q2 = q*q
   
    Z = sdata(sZ)

    @inbounds begin
        for l = 1:q
            offset::Int = 0
            scra::Float64 = 0.0
            for i = 1:site-1 # Begin sum_i \neq site J
                scra += vecJ[offset + l + q * (Z[i,a]-1)] 
                offset += q2 
            end
            # skipping sum over residue site
    	    for i = site+1:N
                scra += vecJ[offset + l + q * (Z[i,a]-1)] 
                offset += q2 
            end # End sum_i \neq site J
            scra += vecJ[offset + l] # sum H 
            vecene[l] = scra
        end
    end
end

function sumexp(vec::Array{Float64,1})
    
    mysum = 0.0
    @inbounds @simd for i=1:length(vec)
        mysum += exp(vec[i])
    end
    
    return mysum
end

function L2norm(vec::Array{Float64,1}, plmvar::PlmVar)

    LL = length(vec)
    q = plmvar.q

    mysum1 = 0.0
    @inbounds @simd for i=1:(LL-q)
        mysum1 += vec[i] * vec[i]
    end
    mysum1 *= plmvar.lambdaJ

    mysum2 = 0.0
    @inbounds @simd for i=(LL-q+1):LL
        mysum2 += vec[i] * vec[i]
    end
    mysum2 *= plmvar.lambdaH
    
    return mysum1+mysum2
end

nothing 