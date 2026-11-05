# 소리 폴더

여기 있는 파일은 공개 빌드에 들어가는 기본 소리입니다 (CC0, `CREDITS.md`). `SHA256SUMS` 는 이 파일들의 지문이고, `./build.sh` 가 앱에 넣기 전에 대조합니다.

## 소리를 바꾸려면

이 폴더 대신 `sounds-private/` 를 만들어 거기에 넣습니다. 그 폴더는 git 에 올라가지 않습니다.

- `config.json`: Mechvibes 묶음 모양. `key_define_type` 은 `"single"`, `defines` 는 키 번호 → `[시작 ms, 길이 ms]`
- `config.json` 의 `sound` 에 적은 소리 파일: 16비트 PCM 스테레오 WAV
- `config.json` 의 `mouse_sound` 에 적은 소리 파일: 마우스 소리, 위와 같은 모양에 같은 샘플레이트. 없으면 글자 키 소리가 대신 납니다
- `config.json` 의 `mouse_up_sound` 에 적은 소리 파일: 마우스 버튼을 뗄 때 소리, 위와 같은 모양에 같은 샘플레이트. 없으면 뗄 때는 소리가 나지 않습니다

```sh
./build.sh --private
open build/private/Plastikey.app
```

글자·숫자 키는 `defines` 에 있는 조각을 차례로 돌려 씁니다. 스페이스·엔터·백스페이스 같은 나머지 키는 적힌 대로 납니다. 파일이 없거나 모양이 맞지 않으면 빌드가 멈추고 이유를 알려 줍니다.

다른 형식의 소리는 맥에 들어 있는 `afconvert` 로 바꿉니다. Ogg 는 읽지 못합니다.

```sh
afconvert -f WAVE -d LEI16@48000 -c 2 input.mp3 sounds-private/concatenated_audio.wav
```

남이 만든 소리를 공개 저장소에 넣기 전에는 배포해도 되는 소리인지 확인하세요.
