Atari
=====

**Work In Progress**  
Dueling Double DQN with (proportional) prioritised experience replay for the Arcade Learning Environment.

Run `th main.lua` to run headless, or `qlua main.lua` to display the game. The main options are `-game` to choose the ROM (see the [ROM directory](roms/README.md) for more details) and `-mode` as either `train` or `eval`.

**TODO:**

- **Use 4 frames (instead of 1)...**
- Add networking saving and loading
- Add evaluation scripts with [DDQN normalised scores](http://arxiv.org/pdf/1509.06461v3.pdf)
- Add CPU/non-cuDNN support
- Use "sum tree" binary heap for prioritised experience replay
- Add optimiser parameter processor

Requirements
------------

Requires [Torch7](http://torch.ch/) with CUDA support and the following extra packages:

- cudnn
- dpnn
- moses
- xitari
- alewrap

xitari and alewrap can (hopefully) be installed using the following commands:

```sh
luarocks install https://raw.githubusercontent.com/Kaixhin/xitari/master/xitari-0-0.rockspec
luarocks install https://raw.githubusercontent.com/Kaixhin/alewrap/master/alewrap-0-0.rockspec
```
