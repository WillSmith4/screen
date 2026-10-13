# Natywne wideo i wybór renderera

Ustawienia → Video → Rendering Mode zawierają dokładnie dwa tryby: **Standard** (domyślny) i **Metal (Experimental)**. Ustawienie jest globalne, zachowuje się po ponownym uruchomieniu i obowiązuje od następnego połączenia ze sprzętowym dekodowaniem. Wyłączenie sprzętowego dekodowania pozostawia dotychczasową ścieżkę FFmpeg/SDL.

Bezpośrednie dekodowanie sprzętowe H.264/HEVC jest aktywne od iOS/iPadOS 17 (w tym 17.5.1). Na starszych obsługiwanych systemach pozostaje wcześniejszy dekoder FFmpeg/VideoToolbox; minimum aplikacji nadal wynosi iOS 15. Te systemy nie mają nowych kluczy API wymagających sprzętowego dekodera.

## Przepływ obrazu

```mermaid
flowchart LR
  Android[Android MediaCodec] --> ADB[Pakiety scrcpy / ADB]
  ADB --> Native[Annex-B i CoreMedia]
  Native --> VT[VideoToolbox: H.264 / HEVC]
  VT --> Surface[CVPixelBuffer / IOSurface]
  Surface --> Output[Serial user-interactive output queue]
  Output --> Presenter[ScrcpyFramePresenter]
  Clock[CADisplayLink Standard do 120 Hz] --> Presenter
  MetalClock[CAMetalDisplayLink na osobnym wątku] --> Metal
  Setting[Rendering Mode] --> Presenter
  Presenter --> Queue[Standard: FIFO VoidLink]
  Queue --> Standard[AVSampleBufferDisplayLayer]
  Presenter --> MetalQueue[Metal: najnowsza oczekująca klatka]
  MetalQueue --> Metal[CVMetalTextureCache i CAMetalLayer]
```

W ramach jednej sesji tworzony jest tylko wybrany renderer. Nie ma detekcji HDR, tone mappingu, EDR ani przełączania AVSB/Metal według metadanych koloru. Metal obsługuje SDR NV12 i P010 (10 bitów samo w sobie nie oznacza HDR), zakres pełny/wideo i macierze BT.601/709.

## Co pochodzi z analizy VoidLink

Źródła referencyjne sprawdzono lokalnie w `C:\Users\Admin\Documents\VoidLink-previously-moonlight-zwm\VoidLink`:

| Mechanizm | VoidLink | Nasza implementacja |
|---|---|---|
| Wybór backendu | `Stream/VideoDecoderRenderer.m`, `Base.lproj/iPad.storyboard`, `SettingsSwiftUI.swift` | Te same dwa rodzaje rendererów i nazwy opcji; Standard domyślny. |
| H.264/HEVC | `Stream/VideoDecoderRenderer.m` | Parametry SPS/PPS/VPS, zamiana Annex-B na NAL z długością, CoreMedia → natywne VideoToolbox. |
| Współdzielone bufory GPU | `Metal/MetalVideoRenderer.m` | IOSurface → CVMetalTextureCache → tekstury Y/UV; bez odczytu i przesyłania pikseli przez CPU. |
| Kolejka Standard | `Utility/FrameQueue.m`, `Stream/VideoDecoderRenderer.m` | FIFO, bufor 0–5 (domyślnie 1), naprzemienne odrzucanie, ochrona IDR, oczekiwanie do terminu prezentacji. Szczegóły i test zgodności: [voidlink-standard-pacing.md](voidlink-standard-pacing.md). |
| Prezentacja Standard | `Stream/VideoDecoderRenderer.m` | Cache formatu i gotowe CMSampleBuffer na producencie; bez własnego timebase; output PTS równy targetTimestamp; AVSB bez dodatkowego odrzucania według readiness. |
| Planowanie Metal | Zastąpione mechanizmem Moonlight Qt `57db2001` | CAMetalDisplayLink na stałym NSThread user-interactive; drawable i deadline z callbacku; jedna najnowsza klatka, krótki wait, zwykłe presentDrawable. Szczegóły: [cametaldisplaylink-pacing.md](cametaldisplaylink-pacing.md). |
| Pomiar GPU i prezentacji | `Metal/MetalVideoRenderer.m` | Średnia GPU z wagą 0,25 dla nowej próbki; zwalnianie tekstur i czyszczenie cache po ukończeniu GPU; `addPresentedHandler` / `presentedTime` na urządzeniu iOS. |
| Odbiór dekodowania | `Stream/VideoDecoderRenderer.m`, `_vtq` | Osobna serial queue user-interactive; bufor jest zachowany aż do dostarczenia; reset/close czekają również na tę kolejkę. Łączny limit dekodowania i oczekujących wyników: 3. |
| Priorytet i odświeżanie | `Stream/VideoDecoderRenderer.m`, `Metal/MetalView.m`, `Metal/MetalViewController.m` | Worker user-interactive, CADisplayLink: default mode dla Standard, CAMetalDisplayLink w common modes na osobnym wątku dla Metal; częstotliwość ograniczona możliwościami ekranu. |
| Kolor SDR i geometria | `Metal/MetalVideoRenderer.m` | Przeliczenie YUV na RGB na GPU, zachowanie proporcji obrazu, czarne pasy. |

Standard i dekoder zachowują adaptację VoidLink do scrcpy. Planowanie Metal zastąpiono mechanizmem CAMetalDisplayLink z Moonlight Qt; szczegóły i ograniczenia opisuje [cametaldisplaylink-pacing.md](cametaldisplaylink-pacing.md). Zachowano własny protokół ADB, geometrię wejścia i Drawing Toolkit. Flaga asynchronicznego dekodowania VideoToolbox pozostaje ustawiona jawnie.

**Metal nie ma wybieranego trybu Queue Buffering.** UI pokazuje `Frames to Buffer` i `Async Frame Dequeue` tylko dla Standard. Metal przechowuje jedną najnowszą zdekodowaną klatkę, bez początkowego napełniania; zapisana liczba klatek Standard nie wpływa na ten mechanizm. Zastąpienie oczekującej klatki jest zliczane jako `queueDrops`.

Nie przeniesiono HDR (zgodnie z wymaganiem), interpolacji wymagającej iOS 26, protokołu Sunshine ani eksperymentalnego `Dummy Event`. Ten ostatni wysyła `LiSendKeyboardEvent(0xFF, KEY_ACTION_UP, 0)` do hosta Moonlight/Sunshine. To nie jest neutralny komunikat scrcpy: 255 w przestrzeni kodów Androida oznacza rzeczywisty klawisz. Wysyłanie go lub nowego pakietu no-op przez ADB nie byłoby tym samym mechanizmem ani potwierdzoną optymalizacją iPadOS 17.5.1. Nie zmieniono protokołu sterowania ani serwera Androida. Różnice i źródła: [voidlink-metal-pacing.md](voidlink-metal-pacing.md).

## Własność i odzyskiwanie

Pakiety skompresowane zachowują kolejność i zależności klatek. Po utracie sesji dekodera aplikacja czeka na klatkę kluczową i korzysta z istniejącego ogranicznika żądań resetu Androida. Zmiana formatu, tło, rozłączenie i ponowne połączenie opróżniają prace dekodera przed zmianą stanu. Późny wynik dekodowania nie cofa prezentacji do wcześniejszego PTS.

AVFrame pozostaje opakowaniem własności i wymiarów wymaganym przez istniejące sinks scrcpy. Dla natywnego H.264/HEVC nie wykonuje dekodowania ani konwersji pikseli. FFmpeg nadal jest potrzebny dla dźwięku, AV1, dekodowania programowego, struktur pakietów i nagrywania. Nie zmieniono przypiętych wersji zależności, enkodera Androida, bitrate ani rozdzielczości.

W trybie natywnym porting `screen.c` zachowuje obsługę okna, zdarzeń i geometrii, ale pomija tworzenie tekstury SDL, clear, draw i present/flush. Poprzednio pomijane były tylko przesyłanie YUV i present; clear/draw/flush nadal wykonywały dodatkową pracę GPU na niewidocznej powierzchni SDL.

Nowy renderer wymaga bezpośredniego linkowania systemowego `Metal.framework` w aplikacji. Kontrola zgodności dopuszcza dokładnie ten dodatkowy framework Apple i nadal sprawdza pozostałe biblioteki, ich wersje oraz komplet zasobów. Nie jest to nowa biblioteka zewnętrzna ani aktualizacja FFmpeg/SDL.

## Walidacja

- `test_annexb.c`: prefiksy 3/4 bajty, granice danych, padding, emulation prevention i puste NAL.
- `test-native-video.sh`: rzeczywiste próbki H.264 i HEVC, zmiany wymiarów, IOSurface, reset, oczekiwanie na IDR, błędne dane i asynchroniczna seria klatek.
- `NativeVideoTests.m`: piksele z rzeczywistego GPU Metal, kolory podstawowe, czerń/biel, zakres pełny/wideo, P010 SDR, proporcje i własność bufora do ukończenia GPU.
- `FrameQueueTests.m`: 60 000 operacji porównanych z niezmienioną metodą kolejki VoidLink, cache formatu, oczekiwanie i ograniczenie fizycznej pojemności.
- `FramePresenterTests.m`: FIFO/prefill, output PTS, callback na main, brak własnego timebase, oczekiwanie, odrzucanie wyników starej sesji, żywy CADisplayLink, własność klatek oraz wyłączność warstw po zmianie Standard → Metal → Standard.
- Ten sam test wymusza zatrzymanie pierwszej pracy Metal i serię trzech kolejnych klatek. Przy zablokowanym głównym wątku kontrolowany CAMetalDisplayLink pracuje na osobnym wątku, zachowuje najnowszą oczekującą klatkę, rozróżnia sukces/busy/błąd i wraca po pauzie. Osobny etap sprawdza rzeczywisty callback CAMetalDisplayLink w symulatorze.
- Nowe kontrole sprawdzają ten sam żyjący NSThread po opróżnieniu oczekującej klatki, pobranie pojedynczej klatki bez prefill mimo ustawienia Standard=3, anulowanie pustego oczekiwania, dostarczenie wyników dekodowania przed zakończeniem drain oraz odrzucanie statystyk starej sesji.
- `test_native_render_sdl.c`: produkcyjne funkcje routingu nie wywołują żadnej dodatkowej operacji SDL GPU w trybie natywnym; pozostałe tryby przekazują argumenty i błędy, również dla obrotu.
- Pozostają testy dotyku, Drawing Toolkit, Androida i porównanie bibliotek/zasobów IPA z v4.6.0.

Testy Maca i symulatora nie mierzą fizycznych 120 FPS ani opóźnienia Xiaomi → iPad. Na iPadzie Pro M2 / iPadOS 17.5.1 należy porównać oba tryby przy identycznym kodeku, rozdzielczości, bitrate i FPS=120, osobno dla H.264 i HEVC. Sprawdzić przewijanie, Pencil, obrót, multitasking, przejście do tła, nagrywanie i reconnect. Log `[NativeVideo]` potwierdza ścieżkę dekodowania; `[FramePacing] renderer=...` potwierdza backend. Nowe liczniki opisano w [fps-log-investigation-2026-10-13.md](fps-log-investigation-2026-10-13.md). `submitted` oznacza klatki przekazane do prezentacji, nie fizyczny pomiar ekranu; stary `--print-fps` mierzy obsługę klatek przez SDL.
