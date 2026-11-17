-- =====================================================================
--  Fiszki łacińskie – baza użytkowników (Supabase / PostgreSQL)
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Przed uruchomieniem zmień TWOJE_HASLO na końcu pliku.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Lista osób, które weszły na stronę ------------------------------------
create table if not exists public.uzytkownicy (
  id                 uuid primary key default gen_random_uuid(),
  imie_nazwisko      text not null,
  pierwsze_wejscie   timestamptz not null default now(),
  ostatnia_aktywnosc timestamptz not null default now(),
  liczba_wejsc       integer not null default 1,
  urzadzenie         text
);
create index if not exists uzytkownicy_nazwa_idx on public.uzytkownicy (lower(imie_nazwisko));

-- Ustawienia (hash hasła administratora) --------------------------------
create table if not exists public.ustawienia (
  klucz   text primary key,
  wartosc text not null
);

-- Nikt z zewnątrz nie czyta ani nie zapisuje tabel bezpośrednio.
-- Dostęp wyłącznie przez funkcje poniżej.
alter table public.uzytkownicy enable row level security;
alter table public.ustawienia  enable row level security;
revoke all on public.uzytkownicy from anon, authenticated;
revoke all on public.ustawienia  from anon, authenticated;

-- Zgłoszenie wejścia / aktywności użytkownika -------------------------------
-- p_id: id zapamiętane w przeglądarce (null przy pierwszym wejściu)
-- p_nowa_wizyta: true przy otwarciu strony, false przy zwykłej aktywności
create or replace function public.zglos_uzytkownika(
  p_id uuid, p_nazwa text, p_urzadzenie text, p_nowa_wizyta boolean
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_nazwa text := btrim(regexp_replace(coalesce(p_nazwa, ''), '\s+', ' ', 'g'));
  v_id uuid;
begin
  if length(v_nazwa) < 3 or length(v_nazwa) > 80 then
    raise exception 'Nieprawidłowe imię i nazwisko';
  end if;

  -- 1) to samo urządzenie (znane id) z tym samym imieniem
  if p_id is not null then
    select id into v_id from uzytkownicy where id = p_id and lower(imie_nazwisko) = lower(v_nazwa);
  end if;
  -- 2) ta sama osoba na innym urządzeniu
  if v_id is null then
    select id into v_id from uzytkownicy where lower(imie_nazwisko) = lower(v_nazwa)
      order by ostatnia_aktywnosc desc limit 1;
  end if;

  if v_id is null then
    insert into uzytkownicy (imie_nazwisko, urzadzenie)
      values (v_nazwa, left(p_urzadzenie, 40)) returning id into v_id;
  else
    update uzytkownicy set
      ostatnia_aktywnosc = now(),
      liczba_wejsc = liczba_wejsc + case when p_nowa_wizyta then 1 else 0 end,
      urzadzenie = coalesce(left(p_urzadzenie, 40), urzadzenie)
    where id = v_id;
  end if;
  return v_id;
end $$;

-- Lista użytkowników – tylko z poprawnym hasłem administratora --------------
create or replace function public.lista_uzytkownikow(p_haslo text)
returns table (
  imie_nazwisko text, pierwsze_wejscie timestamptz, ostatnia_aktywnosc timestamptz,
  liczba_wejsc integer, urzadzenie text
)
language plpgsql security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  select wartosc into v_hash from ustawienia where klucz = 'haslo_admina';
  if v_hash is null or v_hash <> crypt(coalesce(p_haslo, ''), v_hash) then
    perform pg_sleep(1);  -- spowalnia zgadywanie hasła
    raise exception 'Nieprawidłowe hasło' using errcode = '28P01';
  end if;
  return query
    select u.imie_nazwisko, u.pierwsze_wejscie, u.ostatnia_aktywnosc, u.liczba_wejsc, u.urzadzenie
    from uzytkownicy u order by u.ostatnia_aktywnosc desc;
end $$;

revoke all on function public.zglos_uzytkownika(uuid, text, text, boolean) from public;
revoke all on function public.lista_uzytkownikow(text) from public;
grant execute on function public.zglos_uzytkownika(uuid, text, text, boolean) to anon, authenticated;
grant execute on function public.lista_uzytkownikow(text) to anon, authenticated;

-- Hasło administratora: ZMIEŃ TWOJE_HASLO przed uruchomieniem ---------------
-- (zapisywany jest tylko hash; ponowne uruchomienie tego fragmentu zmienia hasło)
insert into public.ustawienia (klucz, wartosc)
values ('haslo_admina', extensions.crypt('TWOJE_HASLO', extensions.gen_salt('bf')))
on conflict (klucz) do update set wartosc = excluded.wartosc;
