# Fiszki do nauki

Strona z fiszkami z różnych dziedzin. Fiszki, które znasz, wracają coraz rzadziej, a te, których nie pamiętasz, pojawiają się po chwili ponownie (powtórki rozłożone w czasie, system pudełek Leitnera).

**Strona:** https://tomeeeeek.github.io/fiszki/
**Wersja robocza:** https://tomeeeeek.github.io/fiszki/develop/

## Gałęzie

- `main` – strona główna, publikowana pod `/fiszki/`
- `develop` – wersja robocza do testowania nowych funkcji, publikowana pod `/fiszki/develop/`
  (pasek „WERSJA TESTOWA”, osobna baza Supabase i osobna pamięć przeglądarki)

Nowe funkcje trafiają najpierw na `develop`. Po sprawdzeniu: `git checkout main && git merge develop && git push`.
Obie gałęzie publikuje jeden workflow: `.github/workflows/pages.yml`.

Struktura: **dziedzina → grupa → porcja**.

- Łacina medyczna: określenia medyczne różne, w ortopedii, w neurologii, w innych dziedzinach medycznych
- Anatomia prawidłowa: w przygotowaniu

Funkcje:
- kierunek pytań w obie strony albo na zmianę
- ocena: nie pamiętałem / średnio / pamiętałem; drobne literówki są zaliczane
- statystyki dla każdego użytkownika, panel administratora z postępem wszystkich osób (Supabase)

Dane fiszek są w `index.html`: dziedziny w `SECTIONS`, grupy łaciny w `GROUPS`.
