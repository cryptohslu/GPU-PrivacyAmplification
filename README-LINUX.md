# Running on GNU/Linux

Here are some additional instructions to compile and run this project

## Requirements
- [`libzmq`](https://github.com/zeromq/libzmq)
- vulkan-tools
- glslang

To install all requirements in Arch Linux, run

```shell
# pacman -S cuda zeromq vulkan-tools glslang
```


## Compile

To run on a NVIDIA GeForce GTX 1070

```shell
CUDA_PATH=/opt/cuda SMS=61 make
```
