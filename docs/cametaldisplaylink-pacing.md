# Metal: CAMetalDisplayLink (iPadOS 17+)

Zmiana dotyczy wybranego trybu **Metal (Experimental)**. Standard, dekoder, audio,
Drawing Toolkit, serwer Androida oraz wersje bibliotek pozostają bez zmian.
Nie dodano libplacebo, Vulkan ani MoltenVK. Aplikacja zachowuje minimum iOS 15;
natywna ścieżka wideo i nowy Metal są używane od iOS 17.

## Referencja i adaptacja

Mechanizm opisany w [Moonlight Qt #1598](https://github.com/moonlight-stream/moonlight-qt/issues/1598#issuecomment-3448039876)
wprowadzono w [57db20016a2edfaad540693cf57a7621bd5815f2](https://github.com/moonlight-stream/moonlight-qt/commit/57db20016a2edfaad540693cf57a7621bd5815f2)
(Cameron Gutman / Moonlight contributors, GPL-3.0; ten projekt również GPL-3.0).
To adaptacja mechanizmu, nie przeniesienie macOS/SDL/FFmpeg renderera.

- CAMetalDisplayLink jest połączony z istniejącym CAMetalLayer. Zakres FPS
  odpowiada ustawieniu ograniczonemu możliwościami ekranu; preferredFrameLatency=1.
- Callback dostarcza drawable oraz targetTimestamp. Kod nie wywołuje nextDrawable.
- Jedna najnowsza zdekodowana klatka oczekuje na callback. Nowa zastępuje starą
  i zwiększa queueDrops. Nie ma prefill ani ukrytego wpływu bufora Standard.
- Callback może zaczekać na klatkę przez połowę pozostałego czasu do deadline,
  najwyżej pół okresu klatki. Oczekiwanie budzi nadejście klatki lub zatrzymanie.
- Zwykłe presentDrawable, commit i waitUntilCompleted odpowiadają referencji.
  Nie ma afterMinimumDuration ani czekania na licznik callbacków prezentacji.
  Apple zabrania timed-present dla drawable pochodzącego z CAMetalDisplayLink.
- Rezerwacja limitu prac GPU jest nieblokująca i poprzedza pobranie klatki.
  Brak miejsca pozostawia klatkę oczekującą na następny callback.
- W przeciwieństwie do macOS-owej referencji callback jest na osobnym NSThread
  user-interactive w common run-loop modes. Praca UIKit/SDL na main nie steruje
  renderowaniem. Pauza/stop przerywają oczekiwanie, kończą link na jego wątku,
  dołączają wątek i dopiero potem opróżniają GPU i odłączają warstwę.

Dokumentacja Apple: [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink),
[callback i zasady prezentacji](https://developer.apple.com/documentation/quartzcore/cametaldisplaylinkdelegate/metaldisplaylink(_:needsupdate:)).

## Weryfikacja

FramePresenterTests sprawdza mailbox latest-frame, brak prefill, rezerwację GPU
przed pobraniem, callback poza main, sukces/busy/błąd, pauzę, wznowienie,
przełączenie backendu, zwalnianie obrazów i żywe CADisplayLink/CAMetalDisplayLink
na symulatorze. NativeVideoTests sprawdza piksele GPU i własność buforów,
nieblokującą pojemność GPU oraz liczniki rzeczywistej prezentacji.

Na iPadzie Pro M2 / iPadOS 17.5.1 wybrać Metal (Experimental), FPS=120
oraz identyczny kodek, rozdzielczość i bitrate jak w poprzednim teście.
Połączyć ponownie. Potwierdzić scheduling=CAMetalDisplayLink w logu.
Testować ciągły ruch przez 60 s, sterowanie dotykiem/Pencil, obrót i tło/resume.
Nie zmieniać kilku ustawień naraz.

FramePacing.callbacks w Metal oznacza teraz callbacki CAMetalDisplayLink na
wątku renderowania (wcześniej osobny zegar CADisplayLink na main).
MetalDisplayLink.empty liczy callbacki bez dostępnej klatki; late oznacza
wywołania po deadline; maxCallbackGapMs to największy odstęp między callbackami.
MetalPresentation.presented nadal liczy dodatnie presentedTime; submitted
nie oznacza fizycznie wyświetlonych klatek. queueDrops pozostaje jawnym licznikiem
zastąpionych klatek. Nie zwiększamy FPS przez liczenie powtórzeń tej samej klatki.

Symulator/CI nie dowodzi stabilnych 120 FPS ani identycznej przyczyny jak na macOS.
Wynik wymaga testu sprzętowego. Ta zmiana nie naprawia przestojów trybu Standard.
