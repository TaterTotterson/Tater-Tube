#!/usr/bin/env bash
# Regenerate the original Tater Tube VCR menu sound packs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${repo_root}/assets/audio/menu"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is required to generate the menu sound packs." >&2
    exit 1
fi

render() {
    local pack="$1"
    local cue="$2"
    local duration="$3"
    local fade_start="$4"
    local expression="$5"
    local output_dir="${output_root}/${pack}"

    mkdir -p "${output_dir}"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi \
        -i "aevalsrc=exprs='${expression}':s=48000:d=${duration}" \
        -af "highpass=f=55,lowpass=f=8500,afade=t=out:st=${fade_start}:d=0.025" \
        -ar 48000 -ac 1 -c:a pcm_s16le \
        "${output_dir}/${cue}.wav"
}

# Soft Touch: warm buttons and restrained transport mechanics.
render soft-touch move 0.090 0.065 \
    '0.15*sin(2*PI*980*t)*exp(-42*t)+0.055*sin(2*PI*185*t)*exp(-55*t)+0.035*(2*random(0)-1)*exp(-75*t)'
render soft-touch page 0.180 0.155 \
    '0.15*sin(2*PI*(1350*t-2300*t*t))*exp(-13*t)+0.045*sin(2*PI*210*t)*exp(-22*t)+0.025*(2*random(0)-1)*exp(-25*t)'
render soft-touch back 0.210 0.185 \
    '0.15*sin(2*PI*(430*t-650*t*t))*exp(-12*t)+0.10*sin(2*PI*108*t)*exp(-18*t)+0.025*(2*random(0)-1)*exp(-28*t)'
render soft-touch select 0.170 0.145 \
    'if(lt(t,0.060),0.14*sin(2*PI*720*t)*exp(-22*t),0)+if(between(t,0.045,0.155),0.16*sin(2*PI*1080*(t-0.045))*exp(-24*(t-0.045)),0)+0.025*(2*random(0)-1)*exp(-65*t)'

# Rental Night: crisp front-panel beeps and a lively shuttle mechanism.
render rental-night move 0.075 0.050 \
    '0.12*sin(2*PI*1580*t)*exp(-48*t)+0.065*sin(2*PI*3160*t)*exp(-62*t)+0.035*(2*random(0)-1)*exp(-85*t)'
render rental-night page 0.210 0.185 \
    'if(lt(t,0.090),0.15*sin(2*PI*920*t)*exp(-20*t),0)+if(between(t,0.070,0.195),0.16*sin(2*PI*1380*(t-0.070))*exp(-20*(t-0.070)),0)+0.035*(2*random(0)-1)*exp(-22*t)'
render rental-night back 0.230 0.205 \
    '0.14*sin(2*PI*(980*t-2500*t*t))*exp(-10*t)+0.12*sin(2*PI*92*t)*exp(-15*t)+0.035*(2*random(0)-1)*exp(-24*t)'
render rental-night select 0.190 0.165 \
    'if(lt(t,0.075),0.14*sin(2*PI*1120*t)*exp(-18*t),0)+if(between(t,0.055,0.180),0.17*sin(2*PI*1680*(t-0.055))*exp(-21*(t-0.055)),0)+0.025*(2*random(0)-1)*exp(-70*t)'

# Haunted Tape: worn heads, pitch flutter, and dusty cassette noise.
render haunted-tape move 0.105 0.080 \
    '0.13*sin(2*PI*640*t+0.55*sin(2*PI*23*t))*exp(-31*t)+0.055*sin(2*PI*2440*t)*exp(-58*t)+0.055*(2*random(0)-1)*exp(-46*t)'
render haunted-tape page 0.240 0.215 \
    '0.14*sin(2*PI*(760*t+880*t*t)+0.9*sin(2*PI*11*t))*exp(-9*t)*(0.72+0.28*sin(2*PI*17*t))+0.050*(2*random(0)-1)*exp(-15*t)'
render haunted-tape back 0.260 0.235 \
    '0.15*sin(2*PI*(330*t-410*t*t)+0.65*sin(2*PI*9*t))*exp(-9*t)+0.11*sin(2*PI*76*t)*exp(-13*t)+0.050*(2*random(0)-1)*exp(-17*t)'
render haunted-tape select 0.220 0.195 \
    'if(lt(t,0.095),0.13*sin(2*PI*690*t+0.5*sin(2*PI*19*t))*exp(-14*t),0)+if(between(t,0.065,0.210),0.15*sin(2*PI*1180*(t-0.065)+0.7*sin(2*PI*13*t))*exp(-16*(t-0.065)),0)+0.045*(2*random(0)-1)*exp(-24*t)'

echo "Generated three VCR menu sound packs in ${output_root}"
