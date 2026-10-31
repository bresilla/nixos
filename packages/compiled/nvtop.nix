{ nvtopPackages, cudaPackages }:

# Needs only the NVML header from CUDA, not the multi-GB toolkit.
nvtopPackages.nvidia.override { cudatoolkit = cudaPackages.cuda_nvml_dev; }
