#!/bin/bash
# Overnight, one GPU: record the expressive lines with Chatterbox Turbo, keep clean takes, train Mouthy's acoustic
# model with tone control to 100k steps, then fine-tune the vocoder on the new audio. Each step logs to logs/.
cd "${MOUTHY_VOICE_DIR:-$HOME/mouthy-voice}" && source env.sh   # the work folder described in README.md; env.sh sets its paths
step() { echo "$1 exit $2 at $(date)" >> logs/pipeline.log; [ $2 -eq 0 ] || exit $2; }
.venv-chatterbox/bin/python record_expressive.py data/6-expressive > logs/record-expr.log 2>&1; step record $?
.venv/bin/python prep_expressive.py data/6-expressive > logs/prep-expr.log 2>&1; step prep $?
.venv/bin/python mel_stats.py data/mouthy-expr/train.txt Matcha-TTS/configs/data/mouthy-expr.yaml > logs/stats-expr.log 2>&1; step stats $?
.venv/bin/python Matcha-TTS/matcha/train.py experiment=mouthy-expr +trainer.max_steps=100000 test=False > logs/matcha-expr.log 2>&1; step matcha $?
.venv-vocos/bin/python vocos/train.py -c vocos/configs/mouthy-vocos-expr.yaml --ckpt_path archive/vocos-5-crisp-e55-last.ckpt --trainer.max_steps 106000 > logs/vocos-expr.log 2>&1; step vocos $?
