//
// TheosLabOLLVM.cpp
// Ain
//
// Created by Ain on 2026/11/20.
//

#include "bogus/BogusControlFlow.h"
#include "flattening/Flattening.h"
#include "substitution/Substitution.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/CommandLine.h"

using namespace llvm;

static cl::opt<bool> Flatten("fla", cl::desc("Enable control-flow flattening"));
static cl::opt<bool> Substitute("sub", cl::desc("Enable instruction substitution"));
static cl::opt<bool> Bogus("bcf", cl::desc("Enable bogus control flow"));

extern "C" LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "Theos Lab OLLVM", LLVM_VERSION_STRING,
          [](PassBuilder &builder) {
            builder.registerOptimizerLastEPCallback(
                [](ModulePassManager &module, OptimizationLevel) {
                  FunctionPassManager functions;
                  if (Flatten)
                    functions.addPass(FlatteningObfuscatorPass());
                  if (Bogus)
                    functions.addPass(BogusControlFlowPass());
                  if (Substitute)
                    functions.addPass(SubstitutionPass());
                  if (!functions.isEmpty())
                    module.addPass(createModuleToFunctionPassAdaptor(
                        std::move(functions)));
                });
          }};
}
