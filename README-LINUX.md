# Running on GNU/Linux

Here are some additional instructions to compile and run this project

## Requirements

### CUDA implementation
- [`libzmq`](https://github.com/zeromq/libzmq)
- cuda

### Vulkan implementation
- vulkan-tools
- glslang

To install all requirements in Arch Linux, run

```shell
# pacman -S cuda zeromq vulkan-tools glslang
```

At the moment, current `Makefile` does not allow to compile the Vulkan implementation without `cuda`. We should fix this.


## Compile

To run on a NVIDIA GeForce GTX 1070 using CUDA

```shell
CUDA_PATH=/opt/cuda HOST_COMPILER=/opt/cuda/bin/gcc SMS=61 make
```
