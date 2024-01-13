CXX = g++
CXXFLAGS = -O2 -g -Wall -std=c++17
INC=-I./glslang/glslang/Include
#glslang libraries should be under /usr/lib/x86_64-linux-gnu/ - If not build them yourself: cd ./glslang-master/ && mkdir build && cd build &&  cmake .. && make && cd ../../
LIBDIRS = -L./glslang/build/glslang -L./glslang/build/glslang/OSDependent/Unix -L./glslang/build/SPIRV -L./glslang/build/OGLCompilersDLL
LIBS = -pthread -lzmq -lvulkan -l:libSPIRV.a -l:libMachineIndependent.a -l:libGenericCodeGen.a -l:libOSDependent.a -l:libOGLCompiler.a -l:libglslang.a

all:
	sh compileGLSL.sh
	ln -sf PrivacyAmplification.cu PrivacyAmplification.cpp
	$(CXX) $(CXXFLAGS) $(INC) -o PrivacyAmplification PrivacyAmplification.cpp yaml/Yaml.cpp $(LIBDIRS) $(LIBS)
	rm -f PrivacyAmplification.cpp

clean:
	$(RM) PrivacyAmplification
