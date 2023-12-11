#!/usr/bin/env python3

import argparse


parser = argparse.ArgumentParser(
    prog='blog-cli',
    description='Project specific cli tools for convenience',
    epilog='')

subparsers = parser.add_subparsers()
