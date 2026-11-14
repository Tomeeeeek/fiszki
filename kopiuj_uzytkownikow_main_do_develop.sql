-- =====================================================================
--  Kopiowanie użytkowników: baza GŁÓWNA (main) → baza TESTOWA (develop)
--
--  KROK 1: uruchom ten plik w Supabase w projekcie GŁÓWNYM
--          (xiyitawyctgpniijufir): SQL Editor → New query → Run.
--          Wynik to jedna komórka „skrypt_do_bazy_develop” z gotowym poleceniem.
--  KROK 2: skopiuj zawartość tej komórki i uruchom ją w projekcie TESTOWYM
--          (offewerexwuwujwgvxik): SQL Editor → New query → wklej → Run.
--
--  Ten plik tylko CZYTA bazę główną – niczego w niej nie zmienia.
--  Hasło administratora nie jest kopiowane (baza testowa ma własne).
--  Można uruchamiać wielokrotnie: istniejący użytkownicy zostaną zaktualizowani.
-- =====================================================================

select
  'insert into public.uzytkownicy (id, imie_nazwisko, pierwsze_wejscie, ostatnia_aktywnosc, liczba_wejsc, urzadzenie, postep, postep_aktualizacja) values '
  || string_agg(
       format('(%L, %L, %L, %L, %s, %L, %L, %L)',
              id, imie_nazwisko, pierwsze_wejscie, ostatnia_aktywnosc, liczba_wejsc,
              urzadzenie, postep, postep_aktualizacja),
       ', ')
  || ' on conflict (id) do update set'
  || ' imie_nazwisko = excluded.imie_nazwisko,'
  || ' pierwsze_wejscie = excluded.pierwsze_wejscie,'
  || ' ostatnia_aktywnosc = excluded.ostatnia_aktywnosc,'
  || ' liczba_wejsc = excluded.liczba_wejsc,'
  || ' urzadzenie = excluded.urzadzenie,'
  || ' postep = excluded.postep,'
  || ' postep_aktualizacja = excluded.postep_aktualizacja;'
  as skrypt_do_bazy_develop
from public.uzytkownicy;
