-- =====================================================================
--  Aktualizacja 2: postęp użytkowników w panelu administratora
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Hasło administratora pozostaje bez zmian.
-- =====================================================================

alter table public.uzytkownicy add column if not exists postep jsonb;
alter table public.uzytkownicy add column if not exists postep_aktualizacja timestamptz;

-- Zapis podsumowania postępu (wysyła je przeglądarka użytkownika) --------
create or replace function public.zapisz_postep(p_id uuid, p_nazwa text, p_postep jsonb)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_postep is null or jsonb_typeof(p_postep) <> 'object' or pg_column_size(p_postep) > 60000 then
    raise exception 'Nieprawidłowe dane postępu';
  end if;
  update uzytkownicy
     set postep = p_postep, postep_aktualizacja = now(), ostatnia_aktywnosc = now()
   where id = p_id
     and lower(imie_nazwisko) = lower(btrim(regexp_replace(coalesce(p_nazwa, ''), '\s+', ' ', 'g')));
  return found;
end $$;

revoke all on function public.zapisz_postep(uuid, text, jsonb) from public;
grant execute on function public.zapisz_postep(uuid, text, jsonb) to anon, authenticated;

-- Lista użytkowników – teraz razem z postępem ------------------------------
drop function if exists public.lista_uzytkownikow(text);
create function public.lista_uzytkownikow(p_haslo text)
returns table (
  imie_nazwisko text, pierwsze_wejscie timestamptz, ostatnia_aktywnosc timestamptz,
  liczba_wejsc integer, urzadzenie text, postep jsonb, postep_aktualizacja timestamptz
)
language plpgsql security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  select wartosc into v_hash from ustawienia where klucz = 'haslo_admina';
  if v_hash is null or v_hash <> crypt(coalesce(p_haslo, ''), v_hash) then
    perform pg_sleep(1);
    raise exception 'Nieprawidłowe hasło' using errcode = '28P01';
  end if;
  return query
    select u.imie_nazwisko, u.pierwsze_wejscie, u.ostatnia_aktywnosc, u.liczba_wejsc, u.urzadzenie,
           u.postep, u.postep_aktualizacja
    from uzytkownicy u order by u.ostatnia_aktywnosc desc;
end $$;

revoke all on function public.lista_uzytkownikow(text) from public;
grant execute on function public.lista_uzytkownikow(text) to anon, authenticated;
