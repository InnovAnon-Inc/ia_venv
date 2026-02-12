#! /usr/bin/env python
# cython: language_level=3
# distutils: language=c++

import ast
from contextlib  import ExitStack, contextmanager
from dataclasses import dataclass
import dis
import hashlib
import importlib
import inspect
from io          import StringIO
import logging
import multiprocessing
import os
from pathlib     import Path
import platform
import re
import shlex
import shutil
import socket
import subprocess
from subprocess  import Popen
import sys
import sysconfig
import time
import tomllib
from types       import *
from typing      import *

import venv

def is_venv()->bool:
    _is_venv   :bool          = (sys.prefix != sys.base_prefix)
    virtual_env:Optional[str] = os.getenv('VIRTUAL_ENV')
    if(not _is_venv):
        logging.info('is not venv')
        assert(virtual_env is None)
        return False
    assert _is_venv
    assert(virtual_env == sys.prefix)
    logging.info('is venv')
    return True

def create_venv(venv_dir:Path, clobber:bool=False)->None:
    import venv
    logging.info(f'creating venv: {venv_dir}')
    assert clobber or (not os.path.exists(venv_dir))
    builder: venv.EnvBuilder = venv.EnvBuilder(
            #system_site_packages=False,   # a Boolean value indicating that the system Python site-packages should be available to the environment (defaults to False).
            clear                =True,    # a Boolean value which, if true, will delete the contents of any existing target directory, before creating the environment.
            #symlinks            =False,   # a Boolean value indicating whether to attempt to symlink the Python binary rather than copying.
            upgrade              =True,    # a Boolean value which, if true, will upgrade an existing environment with the running Python - for use when that Python has been upgraded in-place (defaults to False).
            with_pip             =True,    # a Boolean value which, if true, ensures pip is installed in the virtual environment. This uses ensurepip with the --default-pip option.
            #prompt              =None,    # a String to be used after virtual environment is activated (defaults to None which means directory name of the environment would be used).
                                           # If the special string "." is provided, the basename of the current directory is used as the prompt.
            upgrade_deps         =False,   # Update the base venv modules to the latest on PyPI
    )
    builder.create(venv_dir)
    assert os.path.isdir(venv_dir)

def create_venv_if_not_exists(venv_dir:Path, clobber:bool=False)->bool:
    if (not clobber) or os.path.exists(venv_dir):
        logging.info(f'venv exists: {venv_dir}')
        assert os.path.isdir(venv_dir)
        return False
    logging.info(f'venv does not exist: {venv_dir}')
    assert clobber or (not os.path.exists(venv_dir))
    #with bootstrapped(dependencies={ 'venv'            : 'venv', }):            # host requires venv
    create_venv(venv_dir, clobber=clobber)
    assert os.path.isdir(venv_dir)
    return True

@contextmanager
def activate(venv_dir:Path, )->Generator[None,None]:
    _activate(venv_dir, )
    try:
        logging.info(f'enter venv activation critical section: {venv_dir}')
        yield
        logging.info(f'leave venv activation critical section: {venv_dir}')
    finally:
        deactivate()

def _activate(venv_dir:Path,)->None:
    logging.info(f'activating venv: {venv_dir}; must de-activate first')
    # This file must be used with "source bin/activate" *from bash*
    # You cannot run it directly

    # unset irrelevant variables
    #deactivate nondestructive
    deactivate(nondestructive=True,)
    logging.info('venv de-activated; now activating fr')

    # on Windows, a path can contain colons and backslashes and has to be converted:
    #if [ "${OSTYPE:-}" = "cygwin" ] || [ "${OSTYPE:-}" = "msys" ] ; then
    #    # transform D:\path\to\venv to /d/path/to/venv on MSYS
    #    # and to /cygdrive/d/path/to/venv on Cygwin
    #    export VIRTUAL_ENV=$(cygpath "/home/frederick/venv")
    #else
    #    # use the path as-is
    #    export VIRTUAL_ENV="/home/frederick/venv"
    #fi
    assert venv_dir.is_dir()
    os.environ['VIRTUAL_ENV'] = str(venv_dir) # TODO

    #_OLD_VIRTUAL_PATH="$PATH"
    #PATH="$VIRTUAL_ENV/bin:$PATH"
    #export PATH
    path :str = os.getenv('PATH', '')
    #logging.info(f'path: {path}')
    #pathl:List[str] = os.pathsep.split(path)
    pathl:List[str] = path.split(os.pathsep)
    #logging.info(f'path list: {pathl}')
    prepend_path:str = venv_dir / 'bin'
    assert Path(prepend_path).is_dir()
    pathl.insert(0, str(prepend_path))
    path = os.pathsep.join(pathl)
    os.environ['PATH'] = path
    #logging.info(f'path: {path}')

    # unset PYTHONHOME if set
    # this will fail if PYTHONHOME is set to the empty string (which is bad anyway)
    # could use `if (set -u; : $PYTHONHOME) ;` in bash
    #if [ -n "${PYTHONHOME:-}" ] ; then
    #    _OLD_VIRTUAL_PYTHONHOME="${PYTHONHOME:-}"
    #    unset PYTHONHOME
    #fi
    pythonhome:str = os.getenv('PYTHONHOME', '')
    if pythonhome:
        os.environ['_OLD_VIRTUAL_PYTHONHOME'] = pythonhome
        os.environ.pop('PYTHONHOME', None)

    #if [ -z "${VIRTUAL_ENV_DISABLE_PROMPT:-}" ] ; then
    #    _OLD_VIRTUAL_PS1="${PS1:-}"
    #    PS1="(venv) ${PS1:-}"
    #    export PS1
    #    VIRTUAL_ENV_PROMPT="(venv) "
    #    export VIRTUAL_ENV_PROMPT
    #fi
    virtual_env_disable_prompt:str = os.getenv('VIRTUAL_ENV_DISABLE_PROMPT', '')
    if(not virtual_env_disable_prompt):
        ps1:str = os.getenv('PS1', '')
        os.environ['_OLD_VIRTUAL_PS1'] = ps1
        virtual_env_prompt:str = '(venv) '
        os.environ['VIRTUAL_ENV_PROMPT'] = virtual_env_prompt
        ps1 = virtual_env_prompt + ps1
        os.environ['PS1'] = ps1

    # Call hash to forget past commands. Without forgetting
    # past commands the $PATH changes we made may not be respected
    #hash -r 2> /dev/null
    #assert is_venv() # broken by: assert(virtual_env is None)

def deactivate(nondestructive:bool=False,)->None:
    """ reset old environment variables """
    logging.info(f'deactivating venv: {nondestructive}')

    #if [ -n "${_OLD_VIRTUAL_PATH:-}" ] ; then
    #    PATH="${_OLD_VIRTUAL_PATH:-}"
    #    export PATH
    #    unset _OLD_VIRTUAL_PATH
    #fi
    old_virtual_path:str = os.getenv('_OLD_VIRTUAL_PATH', '')
    if old_virtual_path:
        os.environ['PATH'] = old_virtual_path
        os.environ.pop('_OLD_VIRTUAL_PATH', None)

    #if [ -n "${_OLD_VIRTUAL_PYTHONHOME:-}" ] ; then
    #    PYTHONHOME="${_OLD_VIRTUAL_PYTHONHOME:-}"
    #    export PYTHONHOME
    #    unset _OLD_VIRTUAL_PYTHONHOME
    #fi
    old_virtual_pythonhome:str = os.getenv('_OLD_VIRTUAL_PYTHONHOME', '')
    if old_virtual_pythonhome:
        os.environ['PYTHONHOME'] = old_virtual_pythonhome
        os.environ.pop(old_virtual_pythonhome, None)

    # Call hash to forget past commands. Without forgetting
    # past commands the $PATH changes we made may not be respected
    #hash -r 2> /dev/null

    #if [ -n "${_OLD_VIRTUAL_PS1:-}" ] ; then
    #    PS1="${_OLD_VIRTUAL_PS1:-}"
    #    export PS1
    #    unset _OLD_VIRTUAL_PS1
    #fi
    old_virtual_ps1:str = os.getenv('_OLD_VIRTUAL_PS1', '')
    if old_virtual_ps1:
        os.environ['PS1'] = old_virtual_ps1
        os.environ.pop('_OLD_VIRTUAL_PS1', None)
    
    #unset VIRTUAL_ENV
    #unset VIRTUAL_ENV_PROMPT
    os.environ.pop('VIRTUAL_ENV',None)
    os.environ.pop('VIRTUAL_ENV_PROMPT',None)

    assert(not is_venv())
    #if [ ! "${1:-}" = "nondestructive" ] ; then
    ## Self destruct!
    #    unset -f deactivate
    #fi
    if nondestructive:
        return

    raise NotImplementedError() # TODO

def default_venv_dir()->Path:
    return Path.home() / 'venv'

def get_venv_dir(venv_dir:Path|None=None)->Path:
    return venv_dir or default_venv_dir()

def get_venv_executable(venv_dir:Path)->Path:
    if sys.platform == "win32":
        venv_executable = venv_dir / "Scripts" / "python.exe"
    else:
        venv_executable = venv_dir / "bin" / "python"
    assert venv_executable.exists()
    return venv_executable

def get_new_argv(venv_executable:Path)->List[str]:
    logging.info(f'sys      argv: {sys.argv}')
    logging.info(f'sys orig argv: {sys.orig_argv}')
    return [str(venv_executable)] + sys.orig_argv[1:]

def reexec_in_venv(venv_dir:Path)->None:
    venv_executable:Path      = get_venv_executable(venv_dir)
    new_argv       :List[str] = get_new_argv(venv_executable)
    logging.info(f'venv executable: {venv_executable}')
    logging.info(f'new  argv      : {new_argv}')
    os.execv(str(venv_executable), new_argv)

def ensure_venv(venv_dir:Path|None=None, clobber:bool=False)->None: # TODO context manager
    if is_venv():
        return
    assert not is_venv()
    logging.info('ensuring venv')
    venv_dir = get_venv_dir(venv_dir)
    #with bootstrapped(dependencies={ 'venv'            : 'venv', }):            # host requires venv
    create_venv_if_not_exists(venv_dir, clobber=clobber)
    with activate(venv_dir, ):
        reexec_in_venv(venv_dir)
        #yield # TODO context manager
    #assert is_venv()

