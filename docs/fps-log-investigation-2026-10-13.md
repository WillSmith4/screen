# Analiza logów FPS z 13 października 2026

Punkt wyjścia: `cdda8ec`, IPA `ScrcpyRemote-4.6.0-voidlink-standard-120Hz.ipa`.
Urządzenie docelowe użytkownika: iPad Pro 12.9 M2, iPadOS 17.5.1. Telefon w logach:
Redmi 2312DRA50G, Android 16. Użytkownik testował grę i test FPS; licznik telefonu
wskazywał 120. Taki licznik nie potwierdza częstotliwości przechwytywania przez MediaCodec.

## Co wynika z otrzymanych logów

Wszystkie trzy sesje żądają H.264, 8 Mb/s, max-size 1080, max-fps 120.
Nie korzystają z `new_display`. Obraz ma 484×1080 (w trzecim logu także obrót).

| Plik użytkownika | Wybrany renderer | Przykład okna 5 s: zegar / dekodowanie / wywołania prezentacji | Odrzucone w kolejce |
|---|---|---|---|
| `Scrcpy_Remote_4.6.0_2026-10-13.log`, wiersz 309 | Standard | 118.9 / 116.7 / 101.9 na sekundę | 74 |
| `Scrcpy_Remote_4.6.0_2026-10-13 2.log`, wiersz 432 | Metal | 119.9 / 113.3 / 81.8 na sekundę | 157 |
| `Scrcpy_Remote_4.6.0_2026-10-13 3.log` | Brak markerów natywnego presentera | Tylko licznik SDL, maksimum 97 FPS | Nieporównywalne z powyższymi licznikami |

Nie jest to dowód blokady 60 Hz. Zegar iPada osiąga około 120 wywołań/s, lecz
między dekoderem a prezentacją są dodatkowe straty. Dopływ klatek też jest zmienny.
Same logi nie rozdzielają ograniczeń Androida, sieci i dekodera ani nie dowodzą,
że usunięcie jednej przyczyny zapewni stabilne 120 odrębnych klatek/s.

Linia `INFO: Renderer: metal` opisuje renderer SDL, a nie ustawienie Standard/Metal.
`--print-fps` inkrementuje licznik przy `sc_screen_apply_frame`, zanim natywna warstwa
pokaże obraz. Nie należy traktować go jako licznika fizycznej prezentacji iPada.
Stary `renderCalls` w Metal zliczał także wywołania zwracające busy/błąd.
`hardware=(null)` wynika z braku wartości diagnostycznej; kod żąda sprzętowego
dekodera. Ta linia nie dowodzi użycia dekodowania programowego.

## Zakres poprawki

1. W natywnym trybie usunięto dodatkowe alokowanie tekstury, clear, draw i flush
   SDL spod warstwy wideo. Okno, zdarzenia, obsługa klatek i geometria nadal działają
   w dotychczasowym kodzie scrcpy. Nie wystarczy samo pominięcie flush: pozostawione
   polecenia rysowania gromadziłyby się w kolejce SDL.
2. Metal korzysta z FIFO z polityką VoidLink, zamiast nadpisywać jedyną oczekującą
   klatkę. Jeden worker przetwarza kolejkę od razu po otrzymaniu danych. CADisplayLink
   utrzymuje ProMotion, ale nie jest dodatkową bramką wywołań renderowania.
3. Worker Metal czeka na dostępność GPU (limit oczekiwania 100 ms), prezentuje przez
   `afterMinimumDuration:1/fps` i czeka na ukończenie polecenia, jak referencja VoidLink
   `2d9558e1`. Na symulatorze używa zwykłego `presentDrawable`. Głównego wątku ani
   producenta klatek nie blokuje to oczekiwanie; pauza/stop opróżniają pracę workera.
4. Logi rozróżniają udane przekazanie do prezentacji, przepełnienie kolejki i błędy
   GPU. Diagnostyka VideoToolbox podaje status odczytu właściwości sprzętowej.

Nie zmieniono wersji zależności, Drawing Toolkit, kodeka/bitrate/rozdzielczości,
serwera Android, polityki kolejki Standard ani domyślnych ustawień buforowania.

## Następny pomiar

Włączyć nagrywanie logów, max-fps 120, tę samą grę/test i parametry połączenia.
Porównać Standard oraz Metal w osobnych połączeniach, po co najmniej 30 sekund ruchu.
Pierwsza linia `[NativePresentation]` potwierdzi pominięcie dodatkowej pracy SDL.

- `[NativeVideoStats] packets`: pakiety z obrazem docierające do dekodera na sekundę;
  `output`: klatki oddane przez dekoder; `maxPacketGapMs`: największa przerwa między
  obsługą pakietów. Przerwa może obejmować także backpressure dekodera, nie tylko sieć.
- `late` i `empty`: wyniki dekodera odrzucone przez kontrolę kolejności/reset oraz
  wywołania output handlera bez obrazu.
- `[FramePacing] decoded`: klatki przyjęte przez presenter; `submitted`: udane
  przekazania do warstwy Standard lub polecenia Metal; `queueDrops`, `gpuBusy`,
  `gpuErrors`: oddzielne przyczyny strat. Zegary obu grup nie mają wspólnego początku,
  więc pojedyncze okna należy porównywać orientacyjnie lub przez dłuższy okres.

Nawet `submitted=120` nie jest pomiarem fizycznie wyświetlonych, różnych klatek.
Wynik końcowy wymaga ponownego testu na urządzeniu użytkownika.
