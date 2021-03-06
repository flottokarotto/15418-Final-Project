#include <cuda_runtime.h>
#include <driver_functions.h>
#include <stdio.h>
#include <limits.h>
#include <assert.h>
#include <time.h>
#include <stdint.h>

extern "C" {
#include "cudaRiver.h"
}

/*struct GlobalConstants {
    //must be in cuda
    int *oopRanks;
    int oopSize;

    //must be in cuda
    int *ipRanks;
    int ipSize;
    int potSize;
    int betSize;
    int afterBetSize;
};*/

__constant__ GlobalConstants cuConsts;

/*#define CHECK_CALL 0
#define CHECK_FOLD 1
#define BET 2
#define OOP_MOVES 3

#define IP_MOVES 4

#define NUM_STRATEGIES_PER_ITERATION 100*/

char **cudaOopStrategies;
int *cudaOutput;
int *output;
uint64_t *cudaPows;

__device__ void setStrategy(char *strategy, uint64_t start, uint64_t *pows) {
    int i = cuConsts.oopSize - 1;
    int toAdd = 0;
    while (start > 0 && i > 0) {
        toAdd = start / pows[i];
        //printf("ToAdd: %d, Start: %d, pows: %d, i: %d\n", toAdd, start, pows[i], i);
        start -= toAdd * pows[i];
        strategy[i] = toAdd;
        i--;
    }
    if (strategy[0] < 0 || strategy[0] >= OOP_MOVES) strategy[0] = 0;
    if (i < 0) assert(0);
}

__device__ void addOne(char *curStrategy) {
    for (int i = 0; i < cuConsts.oopSize; i++) {
        curStrategy[i] = (curStrategy[i] + 1) % OOP_MOVES;
        if (curStrategy[i] != 0) break;
    }
}

//TODO: maybe use extern shared for the curStrategy and the max value
__global__ void kernel_findBestOopStrat(int numThreads, int numBlocks,
        uint64_t numStrategiesPerBlock, uint64_t totalStrategies,
        char **outputStrategy, char **tempStrategies, int *outputValue, uint64_t *pows) {
    int idx = threadIdx.x;
    int block = blockIdx.x;

    outputValue[block] = 0;
    __syncthreads();

    uint64_t startStrategy = numStrategiesPerBlock * block;

    char *strategy = tempStrategies[block];

    setStrategy(strategy, startStrategy, pows);

    int maxStrategy = startStrategy + numStrategiesPerBlock;
    if (maxStrategy > totalStrategies) maxStrategy = totalStrategies;

    int check = 0;
    int bet = 0;
    int call = 0;
    int fold = 0;
    int curMin = INT_MAX;
    int ipRank, oopRank, oopMove, showdown, showPot, showBet;
    for (int m = startStrategy; m < maxStrategy; m++) {
        for (int i = idx; i < cuConsts.ipSize; i += numThreads) {
            ipRank = cuConsts.ipRanks[i];
            for (int j = 0; j < cuConsts.oopSize; j++) {
                oopRank = cuConsts.oopRanks[j];
                oopMove = strategy[j];
                showdown = ipRank > oopRank ? 1 : -1;
                showPot = ipRank > oopRank ? cuConsts.potSize : 0;
                showBet = showPot + (showdown * cuConsts.betSize);

                switch (oopMove) {
                case CHECK_CALL:
                    check += showPot;
                    bet += showBet;
                    break;
                case CHECK_FOLD:
                    check += showPot;
                    bet += cuConsts.potSize;
                    break;
                case BET:
                    call += showBet;
                    break;
                }
            }
            atomicAdd(outputValue + block, max(check,bet) + max(call, fold));

            check = 0;
            bet = 0;
            call = 0;
        }

        __syncthreads();
        if (outputValue[block] < curMin) {
            curMin = outputValue[block];
            for (int i = idx; i < cuConsts.oopSize; i+= numThreads) {
                outputStrategy[block][i] = strategy[i];
            }
        }
        outputValue[block] = 0;
        __syncthreads();
        addOne(strategy);
    }
    outputValue[block] = curMin;

}
/*
__global__ void kernel_calculateValue(int numThreads, int numBlocks,
        char **cudaOopStrategies, int *output) {
    int idx = threadIdx.x;
    int strategyIdx = blockIdx.x;

    int check = 0;
    int bet = 0;
    int call = 0;
    int fold = 0;
    int cb_max = 0;
    int cf_max = 0;
    int ipRank, oopRank, oopMove, showdown, showPot, showBet;
    for (int k = strategyIdx; k < NUM_STRATEGIES_PER_ITERATION; k += numBlocks) {
        char *strategy = cudaOopStrategies[k];
        for (int i = idx; i < cuConsts.ipSize; i += numThreads) {
            ipRank = cuConsts.ipRanks[i];
            for (int j = 0; j < cuConsts.oopSize; j++) {
                oopRank = cuConsts.oopRanks[j];
                oopMove = strategy[j];
                showdown = ipRank > oopRank ? 1 : -1;
                showPot = ipRank > oopRank ? cuConsts.potSize : 0;
                showBet = showPot + (showdown * cuConsts.betSize);
                switch (oopMove) {
                case CHECK_CALL:
                    check += showPot;
                    bet += showBet;
                case CHECK_FOLD:
                    check += showPot;
                    bet += cuConsts.potSize;
                case BET:
                    call += showBet;
                }
            }
            cb_max = check > bet ? check : bet;
            cf_max = call > fold ? call : fold;
            check = cb_max + cf_max;
            //could be a bottleneck
            atomicAdd(output + k, cb_max + cf_max);
            check = 0;
            bet = 0;
            call = 0;
            fold = 0;
        }
    }
}
*/
__global__ void kernel_calculateIpStrat(int numThreads,
        char *strategy, char *betStrategy, char *checkStrategy) {
    int idx = threadIdx.x;

    int check = 0;
    int bet = 0;
    int call = 0;
    int fold = 0;
    int ipRank, oopRank, oopMove, showdown, showPot, showBet;
    for (int i = idx; i < cuConsts.ipSize; i += numThreads) {
        ipRank = cuConsts.ipRanks[i];
        for (int j = 0; j < cuConsts.oopSize; j++) {
            oopRank = cuConsts.oopRanks[j];
            oopMove = strategy[j];
            showdown = ipRank > oopRank ? 1 : -1;
            showPot = ipRank > oopRank ? cuConsts.potSize : 0;
            showBet = showPot + (showdown * cuConsts.betSize);
            switch (oopMove) {
            case CHECK_CALL:
                check += showPot;
                bet += showBet;
                break;
            case CHECK_FOLD:
                check += showPot;
                bet += cuConsts.potSize;
                break;
            case BET:
                call += showBet;
                break;
            }
        }
        checkStrategy[i] = check > bet ? IP_CHECK : IP_BET;
        betStrategy[i] = call > fold ? IP_CALL : IP_FOLD;
        check = 0;
        bet = 0;
        call = 0;
        fold = 0;
    }
}

extern "C"
GlobalConstants *calcGlobalConsts(board_t board, hand_t *oopRange,
        int oopSize, hand_t *ipRange, int ipSize, int potSize, int betSize) {
    GlobalConstants *params = (GlobalConstants *) malloc(sizeof(GlobalConstants));
    int *oopRanks = (int *) malloc(oopSize * sizeof(int));
    int *ipRanks = (int *) malloc(ipSize * sizeof(int));
    for (int i = 0; i < oopSize; i++) {
        oopRanks[i] = rank_of(&board, &oopRange[i]);
        //printf("OopRank[%d]: %d\n", i, oopRanks[i]);
    }
    for (int i = 0; i < ipSize; i++) {
        ipRanks[i] = rank_of(&board, &ipRange[i]);
        //printf("IpRank[%d]: %d\n", i, ipRanks[i]);
    }
    if (cudaMalloc(&(params->oopRanks), sizeof(int) * oopSize) != cudaSuccess) {
        printf("Cuda malloc failed line 106\n");
        assert(0);
    }
    cudaMalloc(&(params->ipRanks), sizeof(int) * ipSize);

    if (cudaMemcpy(params->oopRanks, oopRanks, sizeof(int) * oopSize,
                cudaMemcpyHostToDevice) != cudaSuccess) {
        printf("Cuda Memcpy failed line 109\n");
        assert(0);
    }
    if (cudaMemcpy(params->ipRanks, ipRanks, sizeof(int) * ipSize,
                cudaMemcpyHostToDevice) != cudaSuccess) {
        printf("Cuda Memcpy Failed line 113\n");
        assert(0);
    }

    params->oopSize = oopSize;
    params->ipSize = ipSize;
    params->potSize = potSize;
    params->betSize = betSize;
    params->afterBetSize = potSize + betSize;

    return params;
}

void addOne(char *curStrategy, GlobalConstants *params) {
    for (int i = 0; i < params->oopSize - 1; i++) {
        curStrategy[i] = (curStrategy[i] + 1) % OOP_MOVES;
        if (curStrategy[i] != 0) break;
    }
}

extern "C"
void calcMaxOopStrategy(char *bestStrat, int *stratVal, GlobalConstants *params) {
    if (cudaMemcpyToSymbol(cuConsts, params,
                sizeof(GlobalConstants)) != cudaSuccess) {
        printf("cuda memcpy params failed\n");
        assert(0);
    }

    uint64_t pows[MAX_RANGE];
    for (int i = 0; i < MAX_RANGE; i++) {
        if (i == 0) pows[i] = 1;
        else pows[i] = pows[i-1] * OOP_MOVES;
    }
    if (cudaMalloc(&cudaPows, MAX_RANGE * sizeof(int)) != cudaSuccess) {
        printf("cuda malloc failed cudaPows\n");
        assert(0);
    }
    if (cudaMemcpy(cudaPows, pows, MAX_RANGE * sizeof(int),
                cudaMemcpyHostToDevice) != cudaSuccess) {
        printf("cuda memcpy failed cudaPows\n");
        assert(0);
    }

    uint64_t totalStrategies = 1;
    for (int i = 0; i < params->oopSize; i++) {
        totalStrategies *= OOP_MOVES;
    }

    int numThreads = MAX_THREADS > params->ipSize ? params->ipSize : MAX_THREADS;
    int numBlocks = MAX_BLOCKS < NUM_STRATEGIES_PER_ITERATION
        ? MAX_BLOCKS : NUM_STRATEGIES_PER_ITERATION;
    uint64_t strategiesPerBlock = totalStrategies / numBlocks;
    printf("Num threads: %d, Num blocks: %d, StratPerBlock: %d\n", numThreads, numBlocks, strategiesPerBlock);
    char **oopStrategies =
        (char **) malloc(numBlocks * sizeof(char *));
    if (cudaMalloc(&cudaOopStrategies, numBlocks * sizeof(char *)) != cudaSuccess) {
        printf("Cuda malloc failed cudaOopStrategies\n");
        assert(0);
    }
    for (int i = 0; i < numBlocks; i++) {
        if (cudaMalloc(&oopStrategies[i],
                    params->oopSize * sizeof(char)) != cudaSuccess) {
            printf("cuda malloc failed oopStrategies\n");
            assert(0);
        }
        if (cudaMemset(oopStrategies[i], 0,
                    params->oopSize * sizeof(char)) != cudaSuccess) {
            printf("cuda memset failed oopStrategies\n");
            assert(0);
        }
    }
    if (cudaMemcpy(cudaOopStrategies, oopStrategies, numBlocks * sizeof(char*),
            cudaMemcpyHostToDevice) != cudaSuccess) {
        printf("cuda memcpy failed cudaOopStrategies\n");
        assert(0);
    }

    char **tempStrategies =
        (char **) malloc(numBlocks * sizeof(char *));
    char **cudaTempStrategies;
    if (cudaMalloc(&cudaTempStrategies, numBlocks * sizeof(char *)) != cudaSuccess) {
        assert(0);
    }
    for (int i = 0; i < numBlocks; i++) {
        if (cudaMalloc(&tempStrategies[i],
                    params->oopSize * sizeof(char)) != cudaSuccess) {
            assert(0);
        }
        if (cudaMemset(tempStrategies[i], 0,
                    params->oopSize * sizeof(char)) != cudaSuccess) {
            assert(0);
        }
    }
    if (cudaMemcpy(cudaTempStrategies, tempStrategies, numBlocks * sizeof(char*),
            cudaMemcpyHostToDevice) != cudaSuccess) {
        assert(0);
    }

    int *outputValues = (int *) malloc(numBlocks * sizeof(int));
    int *cudaOutputValues;
    if (cudaMalloc(&cudaOutputValues, numBlocks * sizeof(int)) != cudaSuccess) {
        printf("cuda malloc failed outputValues\n");
        assert(0);
    }

    kernel_findBestOopStrat<<<numBlocks, numThreads>>>(numThreads, numBlocks,strategiesPerBlock, totalStrategies, cudaOopStrategies, cudaTempStrategies, cudaOutputValues, cudaPows);

    cudaDeviceSynchronize();

    if (cudaMemcpy(outputValues, cudaOutputValues, numBlocks * sizeof(int), cudaMemcpyDeviceToHost) != cudaSuccess) {
        printf("Cuda memcpy failed outputValues\n");
        assert(0);
    }
    int minIdx = 0;
    int min = INT_MAX;
    for (int i = 0; i < numBlocks; i++) {
        if (outputValues[i] < min) {
            min = outputValues[i];
            minIdx = i;
        }
    }
    if (cudaMemcpy(bestStrat, oopStrategies[minIdx], params->oopSize * sizeof(char),
                cudaMemcpyDeviceToHost) != cudaSuccess) {
        printf("Cuda memcpy failed bestStrat\n");
        assert(0);
    }
    /*for (int i = 0; i < params->oopSize; i++) {
        printf("%d ", bestStrat[i]);
    }
    printf("\n");*/
}
/*
//calculates the best strategy for the oop player along with the strategies value
extern "C"
void calcMaxStrategy(char *bestStrat, int *stratVal, GlobalConstants *params) {
    if (cudaMemcpyToSymbol(cuConsts, params,
                sizeof(GlobalConstants)) != cudaSuccess) {
        printf("cuda memcpy to symbol failed line 141\n");
        assert(0);
    }


    char **oopStrategies =
        (char **) malloc(NUM_STRATEGIES_PER_ITERATION * sizeof(char *));
    if (cudaMalloc(&cudaOopStrategies,
                NUM_STRATEGIES_PER_ITERATION * sizeof(char *)) != cudaSuccess) {
        printf("Cuda malloc failed line 149\n");
        assert(0);
    }

    for (int i = 0; i < NUM_STRATEGIES_PER_ITERATION; i++) {
        if (cudaMalloc(&oopStrategies[i],
                    params->oopSize * sizeof(char)) != cudaSuccess) {
            printf("cuda malloc failed line 154\n");
            assert(0);
        }
    }
    if (cudaMemcpy(cudaOopStrategies, oopStrategies,
            NUM_STRATEGIES_PER_ITERATION * sizeof(char*),
            cudaMemcpyHostToDevice) != cudaSuccess) {
        printf("cuda memcpy fialed line 160\n");
        assert(0);
    }

    int totalStrategies = 1;
    for (int i = 0; i < params->oopSize; i++) {
        totalStrategies *= OOP_MOVES;
    }
    output = (int *) malloc(NUM_STRATEGIES_PER_ITERATION * sizeof(int));
    if (cudaMalloc(&cudaOutput,
                NUM_STRATEGIES_PER_ITERATION * sizeof(int)) != cudaSuccess) {
        printf("cuda malloc failed line 172\n");
        assert(0);
    }

    char *curStrategy = (char *) malloc(params->oopSize * sizeof(char));
    memset(curStrategy, 0, params->oopSize * sizeof(char));

    int numThreads = MAX_THREADS > params->ipSize ? params->ipSize : MAX_THREADS;
    int numBlocks = MAX_BLOCKS > NUM_STRATEGIES_PER_ITERATION
        ? MAX_BLOCKS : NUM_STRATEGIES_PER_ITERATION;


    char *minStrategy = (char *) malloc(params->oopSize * sizeof(char));
    int minFound = INT_MAX;
    int numIter = totalStrategies / NUM_STRATEGIES_PER_ITERATION;
    if (numIter == 0) numIter = 1;
    clock_t startLoop = clock();
    clock_t start = clock();
    clock_t end;
    //number of kernel invokations needed
    for (int i = 0; i < numIter; i++) {
        //strategies per kernel call
        if (i>0 && i*NUM_STRATEGIES_PER_ITERATION%ITERATIONS_TO_PRINT==0) {
            end = clock();
            double time = (double) (end - start) / CLOCKS_PER_SEC;
            printf("Iteration: %d, Time: %.2f sec, Iterations per second: %.0f\n", i*NUM_STRATEGIES_PER_ITERATION, time, ITERATIONS_TO_PRINT / time);
            start = clock();
        }
        for (int j = 0; j < NUM_STRATEGIES_PER_ITERATION; j++) {
            addOne(curStrategy, params);
            if (cudaMemcpy(oopStrategies[j], curStrategy, params->oopSize *
                        sizeof(char), cudaMemcpyHostToDevice) != cudaSuccess) {
                printf("CudaMemcpy Failed\n");
                assert(0);
            }
        }
        if (cudaMemset(cudaOutput, 0,
                    NUM_STRATEGIES_PER_ITERATION * sizeof(int)) != cudaSuccess) {
            printf("cuda memset failed line 197\n");
            assert(0);
        }
        kernel_calculateValue<<<numBlocks, numThreads>>>
            (numThreads, numBlocks, cudaOopStrategies, cudaOutput);
        if (cudaMemcpy(output, cudaOutput, NUM_STRATEGIES_PER_ITERATION * sizeof(int),
                    cudaMemcpyDeviceToHost) != cudaSuccess) {
            printf("CudaMemcpy Failed\n");
            assert(0);
        }
        cudaDeviceSynchronize();
        //need to synchronize here
        int minIdx = -1;
        //output is the value to the ip strategy, so find the minimum
        for (int k = 0; k < NUM_STRATEGIES_PER_ITERATION; k++) {
            if (output[k] < minFound) {
                minIdx = k;
                minFound = output[k];
            }
        }
        if (minIdx >= 0 && cudaMemcpy(bestStrat, oopStrategies[minIdx],
                    params->oopSize * sizeof(char),
                    cudaMemcpyDeviceToHost) != cudaSuccess) {
            printf("CudaMemcpy Failed\n");
            assert(0);
        }
    }
    *stratVal = minFound;
    clock_t endLoop = clock();
    double time = (double) (endLoop - startLoop) / CLOCKS_PER_SEC;
    printf("Average iterations per second: %2.f\n", totalStrategies / time);
}
*/
extern "C"
void calcMaxIpStrategy(char *bestOopStrat, char *bestIpCheckStrat,
        char *bestIpBetStrat,GlobalConstants *params) {
    char *cudaOopStrat;
    char *cudaIpCheckStrat;
    char *cudaIpBetStrat;
    if (cudaMalloc(&cudaOopStrat, params->oopSize * sizeof(char)) != cudaSuccess) {
        printf("cuda malloc failed line 230\n");
        assert(0);
    }
    if (cudaMemcpy(cudaOopStrat, bestOopStrat, params->oopSize * sizeof(char),
                cudaMemcpyHostToDevice) != cudaSuccess) {
        printf("cuda memcpy failed line 234");
        assert(0);
    }

    if (cudaMalloc(&cudaIpCheckStrat, params->ipSize * sizeof(char)) != cudaSuccess) {
        printf("cuda malloc failed line 239\n");
        assert(0);
    }
    if (cudaMalloc(&cudaIpBetStrat, params->ipSize * sizeof(char)) != cudaSuccess) {
        printf("cuda malloc failed line 239\n");
        assert(0);
    }

    int numThreads = MAX_THREADS > params->ipSize ? params->ipSize : MAX_THREADS;

    kernel_calculateIpStrat<<<1, numThreads>>>
        (numThreads, cudaOopStrat, cudaIpBetStrat, cudaIpCheckStrat);

    if (cudaMemcpy(bestIpCheckStrat, cudaIpCheckStrat, params->ipSize * sizeof(char), cudaMemcpyDeviceToHost) != cudaSuccess) {
        printf("cuda memcpy failed line 299\n");
        assert(0);
    }
    if (cudaMemcpy(bestIpBetStrat, cudaIpBetStrat, params->ipSize * sizeof(char), cudaMemcpyDeviceToHost) != cudaSuccess) {
        printf("cuda memcpy failed line 303\n");
        assert(0);
    }
}
