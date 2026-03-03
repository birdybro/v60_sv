# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a simulation model of the NEC V60 CPU written in SystemVerilog. The reference documentation is `docs/NEC_V60_Programmers_Reference_Manual.pdf`.

## Repository Structure

- **rtl/** — SystemVerilog RTL source files for the V60 CPU model
- **sim/** — Simulation testbenches and related files
- **mame/** — Reference material or comparisons from the MAME emulator's V60 implementation
- **docs/** — Reference documentation (NEC V60 Programmer's Reference Manual)

## Language & Conventions

- Primary language: SystemVerilog (.sv files)
- This is a hardware simulation/modeling project, not a software application
- Follow standard SystemVerilog coding conventions (lowercase with underscores for signals/modules)
