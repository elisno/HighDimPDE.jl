const verbose = true
"""
Multi level Picard algorithm for solving non local non linear PDES.
    
    Arguments:
    * `chain`: a Flux.jl chain with a d-dimensional input and a 1-dimensional output,
    * `strategy`: determines which training strategy will be used,
    * `init_params`: the initial parameter of the neural network,
    * `phi`: a trial solution,
    * `derivative`: method that calculates the derivative.
    
"""
struct MLP <: HighDimPDEAlgorithm
    M::Int # nb of MC integrations
    L::Int # nb of levels
    K::Int # nb MC integration non local term
end
MLP(;M=10,L=2,K=1) = MLP(M,L,K)
    
    
function DiffEqBase.__solve(
    prob::PIDEProblem,
    alg::MLP;
    # mc_sample;
    dt,
    verbose=false,
    multithreading=false
    )
    
    # unbin stuff
    u_domain = prob.u_domain
    x = prob.X0
    d  = length(x)
    K = alg.K
    M = alg.M
    L = alg.L
    g, f, μ, σ, p = prob.g, prob.f, prob.μ, prob.σ, prob.p


    function sde_loop!(y0, y1, s, t)
        randn!(y1)
        dt = t - s
        # @show y1
        y1 .= y0 .- ( μ(y0, p, t) .* dt .+ σ(y0, p, t) .* sqrt(dt) .* y1)
        if !isnothing(u_domain)
            y1 .= _reflect(y0, y1, u_domain[1], u_domain[2])
        end
    end

    if multithreading
        return _ml_picard_mlt(M, L, K, x,prob.tspan[1],prob.tspan[2], sde_loop!, g, f)
    else
        return _ml_picard(M, L, K, x, prob.tspan[1], prob.tspan[2], sde_loop!, g, f)
    end
    
    # sol = DiffEqBase.build_solution(prob,alg,ts,usol)
    # save_everystep ? iters : u0(X0)[1]
end    


function _ml_picard(
                    M, # monte carlo integration
                    L, # level
                    K, # non local term monte carlo
                    x, # initial point                
                    s, # time
                    t, # time
                    sde_loop!, 
                    g, 
                    f,  
                    )
    r = 0.
    a = 0.
    a2 = 0.
    b = 0. 
    for l in 0:(min(L, 2) - 1)
        verbose && println("loop l")
        b = 0.
        num = M^(L - l) # ? why 0.5 in sebastian code?
        for k in 0:num
            verbose && println("loop k")
            r = s + (t - s) * rand()
            x2 = similar(x)
            sde_loop!(x, x2, s, r)
            b2 = _ml_picard(M, l, K, x2, r, t, sde_loop!, g, f)
            b3 = 0.
            # non local integration
            for h in 0:(K-1)
                verbose && println("loop h")
                x3 = randn(size(x))
                b3 += f(x2, x3, b2, _ml_picard(M, l, K, x3, r, t,sde_loop!, g, f),0.,0.,t) #TODO:hardcode, not sure about t
            end
            b += b3 / K
        end
        a += (t - s) * (b / num)
    end
    
    for l in 2:(L-1)
        b = 0.
        num = M^(L - l)
        for k in 1:num
            r = s + (t - s) * rand()
            x2 = similar(x)
            sde_loop!(x, x2, s, r)
            b2 = _ml_picard(M, l, K, x2, r, t, sde_loop!, g, f)
            b4 = _ml_picard(M, l - 1, K, x2, r, t, sde_loop!, g, f)
            b3 = 0.
            # non local integration
            for h in 0:(K-1)
                x3 = randn(size(x))
                x32 = x3
                x34 = x3
                b3 += f(x2, x32, b2, _ml_picard(M, l, K, x32, r, t, sde_loop!, g, f),0.,0.,t) 
                    - f(x2, x34, b4, _ml_picard(M, l - 1, K, x34, r, t), sde_loop!, g, f,0.,0.,t) #TODO:hardcode, not sure about t
            end
            b += b3 / K
        end
        a += (t - s) * (b / num)
    end
    
    num = M^(L)
    for k in 0:(num-1)
        verbose && println("loop k3")
        x2 = similar(x)
        sde_loop!(x, x2, s, t)
        a2 += g(x2)
    end
    
    return a + a2
end

# multithreading version
function _ml_picard_mlt(
                        M, # monte carlo integration
                        L, # level
                        K, # non local term monte carlo
                        x, # initial point
                        s,
                        t,
                        sde_loop!, 
                        g, 
                        f
                        )
    a = Threads.Atomic{Float64}(0.) 
    a2 = Threads.Atomic{Float64}(0.) 
    b = Threads.Atomic{Float64}(0.) 
    for l in 0:(min(L, 2) - 1)
        verbose && println("loop l")
        num = M^(L - l) # ? why 0.5 in sebastian code?
        @Threads.threads for k in 0:num
            verbose && println("loop k")
            r = s + (t - s) * rand()
            x2 = similar(x)
            sde_loop!(x, x2, s, r)
            b2 = _ml_picard(M, l, K, x2, r, t, sde_loop!, g, f)
            b3 = 0.
            # non local integration
            for h in 0:(K-1)
                verbose && println("loop h")
                x3 = randn(size(x))
                b3 += f(x2, x3, b2, _ml_picard(M, l, K, x3, r, t, sde_loop!, g, f),0.,0.,t) #TODO:hardcode, not sure about t
            end
            Threads.atomic_add!(b, b3 / K)
        end
         Threads.atomic_add!(a, (t - s) * (b / num))
    end

    for l in 2:(L-1)
        b = 0.
        num = M^(L - l)
        @Threads.threads for k in 1:num
            r = s + (t - s) * rand()
            x2 = similar(x)
            sde_loop!(x, x2, s, r)
            b2 = _ml_picard(M, l, K, x2, r, t, sde_loop!, g, f)
            b4 = _ml_picard(M, l - 1, x2, r, t, sde_loop!, g, f)
            b3 = 0.
            # non local integration
            for h in 0:(K-1)
                x3 = randn(size(x))
                x32 = x3
                x34 = x3
                b3 += f(x2, x32, b2, _ml_picard(M, l, K, x32, r, t, sde_loop!, g, f), 0.,0.,t) - f(x2, x34, b4, _ml_picard(M, l - 1, K, x34, r, t, sde_loop!, g, f),0.,0.,t) #TODO:hardcode, not sure about t
            end
            Threads.atomic_add!(b, b3 / K)
        end
        Threads.atomic_add!(a, (t - s) * (b / num))
    end

    num = M^(L)
    for k in 0:(num-1)
        verbose && println("loop k3")
        x2 = similar(x)
        sde_loop!(x, x2, s, t)
        a2 += g(x2)
    end

    return a + a2
end