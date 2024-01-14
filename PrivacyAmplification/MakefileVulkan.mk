CXX       = g++
CXXFLAGS  = -std=c++17
CXXFLAGS += -Wall -Wextra
CXXFLAGS += -O2
CXXFLAGS += -g

#INC       = -I/usr/include/glslang/Include/
INC       = -I./glslang/glslang/Include/
INC      += -I./VkFFT/vkFFT -I./VkFFT/benchmark_scripts/vkFFT_scripts/include
LIBS      = -pthread -lzmq -lvulkan
LIBS     += -l:libSPIRV.a -l:libMachineIndependent.a -l:libGenericCodeGen.a -l:libOSDependent.a -l:libOGLCompiler.a -l:libglslang.a
LIBDIRS   = -L./glslang/build/glslang -L./glslang/build/glslang/OSDependent/Unix -L./glslang/build/SPIRV -L./glslang/build/OGLCompilersDLL

.PHONY: all
all: glsl PrivacyAmplification

.PHONY: glsl
glsl:
	sh compileGLSL.sh

utils_VkFFT.o: VkFFT/benchmark_scripts/vkFFT_scripts/src/utils_VkFFT.cpp VkFFT/benchmark_scripts/vkFFT_scripts/include/utils_VkFFT.h
	${CXX} ${CXXFLAGS} ${INC} -c $<

Yaml.o: yaml/Yaml.cpp yaml/Yaml.hpp
	${CXX} ${CXXFLAGS} -c $<

PrivacyAmplification.o: PrivacyAmplification.cpp PrivacyAmplification.h
	${CXX} ${CXXFLAGS} ${INC} -c $<


PrivacyAmplification: PrivacyAmplification.o utils_VkFFT.o Yaml.o
	${CXX} ${CXXFLAGS} ${INC} -o $@ $^ ${LIBDIRS} ${LIBS}

clean:
	${RM} -v *.o PrivacyAmplification
	${RM} -r SPIRV
