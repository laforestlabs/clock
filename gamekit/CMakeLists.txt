# Dual-purpose build for the gamekit runtime.
#
# The same directory is consumed two completely different ways:
#
#   ESP-IDF  treats it as a component and calls idf_component_register.
#            The FFI facade and the host CLI/tests are excluded; firmware
#            has no use for them.
#
#   Host     compiles it via Makefile.host (game-cli and the tests), which
#            globs src/*.c and examples/*/*.c and never sees this file.
#
# The firmware compiles the runtime, all five example games, and the small
# firmware registry (fw/) that maps game ids to vtables.
if(ESP_PLATFORM)
    idf_component_register(
        SRCS
            src/runtime.c
            src/net_loopback.c
            src/view.c
            examples/rally/game_rally.c
            examples/snake/game_snake.c
            examples/tetris/game_tetris.c
            examples/breakout/game_breakout.c
            examples/invaders/game_invaders.c
            examples/probe/game_probe.c
            fw/game_registry.c
        INCLUDE_DIRS "include" "fw"
        REQUIRES mirror_core
    )
    return()
endif()
