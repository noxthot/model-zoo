# TODO: Change this to relative import
include("vision/diffusion_mnist/diffusion_mnist.jl")

using Plots

function diffusion_coeff(t, sigma=25.0f0)
    sigma .^ t
end

function convert_to_image(x, y_size)
    Gray.(
        permutedims(
            vcat(
                reshape.(
                    chunk(x |> cpu, y_size), 28, :
                )...
            ),
            (2, 1)
        )
    )
end

"""
Helper function that generates inputs to a sampler.
"""
function setup_sampler(model, device, num_images=5, num_steps=500, ϵ=1.0f-3)
    t = ones(Float32, num_images) |> device
    init_x = (
        randn(Float32, (28, 28, 1, num_images)) .*
        expand_dims(model.marginal_prob_std(t), 3)
    ) |> device
    time_steps = LinRange(1.0f0, ϵ, num_steps)
    Δt = time_steps[1] - time_steps[2]
    return time_steps, Δt, init_x
end

"""
Sample from a diffusion model using the Euler-Maruyama method.

# References
https://yang-song.github.io/blog/2021/score/#how-to-solve-the-reverse-sde
"""
function Euler_Maruyama_sampler(model, init_x, time_steps, Δt)
    x = mean_x = init_x
    progress = Progress(length(time_steps))
    for time_step in time_steps
        batch_time_step = ones(Float32, size(init_x)[end]) * time_step |> device
        g = diffusion_coeff(batch_time_step)
        mean_x = x .+ expand_dims((g .^ 2), 3) .* model(x, batch_time_step) .* Δt
        x = mean_x + sqrt(Δt) * expand_dims(g, 3) .* randn(Float32, size(x))
        next!(progress; showvalues=[(:time_step, time_step)])
    end
    return mean_x
end

"""
Sample from a diffusion model using the Predictor-Corrector method.

# References
https://yang-song.github.io/blog/2021/score/#how-to-solve-the-reverse-sde
"""
function predictor_corrector_sampler(model, init_x, time_steps, Δt, snr=0.16f0)
    x = mean_x = init_x
    progress = Progress(length(time_steps))
    for time_step in time_steps
        batch_time_step = ones(Float32, size(init_x)[end]) * time_step |> device
        # Corrector step (Langevin MCMC)
        grad = model(x, batch_time_step)
        num_pixels = prod(size(grad)[1:end-1])
        grad_batch_vector = reshape(grad, (size(grad)[end] , num_pixels))
        grad_norm = sqrt.(sum(abs2, grad_batch_vector, dims=2))
        grad_norm = sum(grad_norm) / length(grad_norm)
        noise_norm = sqrt(num_pixels)
        langevin_step_size = 2 * (snr * noise_norm / grad_norm) ^ 2
        x = x .+ langevin_step_size .* grad .+ sqrt(2 * langevin_step_size) .* randn(Float32, size(x))
        # Predictor step (Euler-Maruyama)
        g = diffusion_coeff(batch_time_step)
        mean_x = x .+ expand_dims((g .^ 2), 3) .* model(x, batch_time_step) .* Δt
        x = mean_x + sqrt.(expand_dims((g .^ 2), 3) .* Δt) .* randn(Float32, size(x))
        next!(progress; showvalues=[(:time_step, time_step)])
    end
    return mean_x
end

function plot_result()
    BSON.@load "vision/diffusion_mnist/output/model.bson" unet args
    args = Args(; args...)
    device = args.cuda && CUDA.has_cuda() ? gpu : cpu
    unet = unet |> device
    time_steps, Δt, init_x = setup_sampler(unet, device)
    @info "Start Euler-Maruyama Sampling"
    euler_maruyama = Euler_Maruyama_sampler(unet, init_x, time_steps, Δt)
    sampled_noise = convert_to_image(init_x, size(init_x)[end])
    save(joinpath(args.save_path, "sampled_noise.png"), sampled_noise)
    em_images = convert_to_image(euler_maruyama, size(euler_maruyama)[end])
    save(joinpath(args.save_path, "em_images.png"), em_images)
    @info "Start PC Sampling"
    pc = predictor_corrector_sampler(unet, init_x, time_steps, Δt)
    pc_images = convert_to_image(pc, size(pc)[end])
    save(joinpath(args.save_path, "pc_images.png"), pc_images)
end

if abspath(PROGRAM_FILE) == @__FILE__
    plot_result()
end
