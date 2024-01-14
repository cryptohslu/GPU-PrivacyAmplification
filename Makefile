.PHONY: vulkan
vulkan: vulkan-impl files examples

.PHONY: cuda
cuda: cuda-impl files examples

.PHONY: all
all: vulkan-impl cuda-impl files examples

.PHONY: vulkan-impl
vulkan-impl:
	mkdir -p build
	${MAKE} -C PrivacyAmplification vulkan
	cp -a PrivacyAmplification/PrivacyAmplification ./build
	cp -a PrivacyAmplification/SPIRV ./build

.PHONY: cuda-impl
cuda-impl: files
	mkdir -p build
	${MAKE} -C PrivacyAmplification cuda
	cp -a PrivacyAmplification/PrivacyAmplificationCuda ./build

.PHONY: examples
examples:
	mkdir -p build
	for example in SendKeysExample MatrixSeedServerExample ReceiveAmpOutExample LargeBlocksizeExample ; do \
		${MAKE} -C examples/$$example ; \
		cp -a examples/$$example/$$example ./build ; \
	done

.PHONY: files
files:
	mkdir -p build
	cp -a PrivacyAmplification/keyfile.bin ./build
	cp -a PrivacyAmplification/toeplitz_seed.bin ./build
	cp -a PrivacyAmplification/ampout.sh3 ./build
	cp -a PrivacyAmplification/config.yaml ./build/config.yaml

.PHONY: clean
clean:
	${RM} -rf build
	${MAKE} -C PrivacyAmplification clean
	for example in SendKeysExample MatrixSeedServerExample ReceiveAmpOutExample LargeBlocksizeExample ; do \
		${MAKE} -C examples/$$example clean ; \
	done
