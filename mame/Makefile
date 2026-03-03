# mame/Makefile — Build standalone MAME V60 reference harness

CXX      ?= g++
CXXFLAGS  = -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS   =

SRC_DIR   = src
BUILD_DIR = build_out
TARGET    = $(BUILD_DIR)/v60_harness

SRCS      = $(SRC_DIR)/v60_harness.cpp
HEADERS   = $(SRC_DIR)/mame_stubs.h

.PHONY: all build clean run

all: build

build: $(TARGET)

$(TARGET): $(SRCS) $(HEADERS)
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -I$(SRC_DIR) $(SRCS) -o $(TARGET) $(LDFLAGS)

run: $(TARGET)
	$(TARGET) -trace mame.trace

clean:
	rm -rf $(BUILD_DIR) *.trace
