#!/bin/env bash

# Script para compilar y hacer deploy de  myLemonade.

git submodule update --init --recursive
#git submodule update --remote lemonade

docker  compose build  mylemonade

