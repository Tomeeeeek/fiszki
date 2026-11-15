-- =====================================================================
--  Aktualizacja 6: logowanie adresem e-mail
--  Wymaga aktualizacji 5 (supabase_5_konta.sql).
--  Wklej całość w Supabase: SQL Editor → New query → Run
--  (jeśli Supabase zapyta o „destructive operation” – potwierdź).
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej.
--
--  • Konta rozróżnia e-mail (unikalny). Imię i nazwisko to nazwa widoczna
--    dla innych – może się powtarzać.
--  • Logowanie: e-mail + hasło.
--  • Konta bez e-maila dostają go przy następnym wejściu (dodaj_email – zalogowani)
--    albo przy logowaniu (przenies_konto – imię i nazwisko + obecne hasło, jeśli było).
-- =====================================================================

alter table public.uzytkownicy add column if not exists email text;
create unique index if not exists uzytkownicy_email_uidx on public.uzytkownicy (lower(email)) where email is not null;
drop index if exists public.uzytkownicy_nazwa_uidx;
create index if not exists uzytkownicy_nazwa_idx on public.uzytkownicy (lower(imie_nazwisko));

-- Zmienia się lista parametrów – stare wersje trzeba usunąć
drop function if exists public.zaloguj(text, text, text);
drop function if exists public.ustaw_haslo(text, text, text);
drop function if exists public.zaloz_konto(text, text, text);
drop function if exists public.lista_uzytkownikow(uuid);

-- Pomocnicze -----------------------------------------------------------------
create or replace function public._email(p text) returns text
language plpgsql immutable as $$
declare v text := lower(btrim(coalesce(p, '')));
begin
  if length(v) > 120 or v !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then
    raise exception 'Nieprawidłowy adres e-mail' using errcode = 'KN010';
  end if;
  return v;
end $$;

create or replace function public._sprawdz_nazwe(p text) returns text
language plpgsql immutable as $$
declare v text := _nazwa(p);
begin
  if length(v) > 80 or coalesce(array_length(string_to_array(v, ' '), 1), 0) < 2
     or exists (select 1 from unnest(string_to_array(v, ' ')) w where length(w) < 2) then
    raise exception 'Wpisz pełne imię i nazwisko' using errcode = 'KN004';
  end if;
  return v;
end $$;

create or replace function public._email_wolny(p_email text, p_poza uuid) returns void
language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from uzytkownicy where lower(email) = p_email and id is distinct from p_poza) then
    raise exception 'Ten adres e-mail jest już używany' using errcode = 'KN007';
  end if;
end $$;

create or replace function public._nowa_sesja(p_id uuid, p_urzadzenie text, p_nowa_wizyta boolean) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_token uuid; v_u uzytkownicy;
begin
  delete from sesje where uzytkownik = p_id and ostatnio < now() - interval '180 days';
  insert into sesje (uzytkownik) values (p_id) returning token into v_token;
  update uzytkownicy set ostatnia_aktywnosc = now(),
         liczba_wejsc = liczba_wejsc + case when p_nowa_wizyta then 1 else 0 end,
         urzadzenie = coalesce(left(p_urzadzenie, 40), urzadzenie)
   where id = p_id returning * into v_u;
  return jsonb_build_object('token', v_token, 'nazwa', v_u.imie_nazwisko, 'admin', v_u.administrator, 'email', v_u.email);
end $$;

revoke all on function public._email(text) from public, anon, authenticated;
revoke all on function public._sprawdz_nazwe(text) from public, anon, authenticated;
revoke all on function public._email_wolny(text, uuid) from public, anon, authenticated;
revoke all on function public._nowa_sesja(uuid, text, boolean) from public, anon, authenticated;

-- Nowe konto ------------------------------------------------------------------
create or replace function public.zaloz_konto(p_nazwa text, p_email text, p_haslo text, p_urzadzenie text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_nazwa text := _sprawdz_nazwe(p_nazwa); v_email text := _email(p_email); v_id uuid;
begin
  if length(coalesce(p_haslo, '')) < 6 then raise exception 'Hasło jest za krótkie' using errcode = 'KN005'; end if;
  perform _email_wolny(v_email, null);
  insert into uzytkownicy (imie_nazwisko, email, urzadzenie, haslo)
    values (v_nazwa, v_email, left(p_urzadzenie, 40), crypt(p_haslo, gen_salt('bf'))) returning id into v_id;
  return _nowa_sesja(v_id, p_urzadzenie, false);
end $$;

-- Logowanie e-mailem ---------------------------------------------------------------
-- KN001 – nie ma konta z tym e-mailem, KN002 – hasło skasowane przez administratora, 28P01 – złe hasło
create or replace function public.zaloguj(p_email text, p_haslo text, p_urzadzenie text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_u uzytkownicy;
begin
  select * into v_u from uzytkownicy where lower(email) = lower(btrim(coalesce(p_email, '')));
  if v_u.id is null then raise exception 'Nie ma konta z tym adresem e-mail' using errcode = 'KN001'; end if;
  if v_u.haslo is null then raise exception 'Konto nie ma hasła' using errcode = 'KN002'; end if;
  if v_u.haslo <> crypt(coalesce(p_haslo, ''), v_u.haslo) then
    perform pg_sleep(1);
    raise exception 'Nieprawidłowe hasło' using errcode = '28P01';
  end if;
  return _nowa_sesja(v_u.id, p_urzadzenie, true);
end $$;

-- Nowe hasło po resecie przez administratora --------------------------------------
create or replace function public.ustaw_haslo(p_email text, p_haslo text, p_urzadzenie text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if length(coalesce(p_haslo, '')) < 6 then raise exception 'Hasło jest za krótkie' using errcode = 'KN005'; end if;
  update uzytkownicy set haslo = crypt(p_haslo, gen_salt('bf'))
   where lower(email) = lower(btrim(coalesce(p_email, ''))) and haslo is null
   returning id into v_id;
  if v_id is null then raise exception 'To konto ma już hasło' using errcode = 'KN006'; end if;
  return _nowa_sesja(v_id, p_urzadzenie, true);
end $$;

-- Zalogowany użytkownik bez e-maila dodaje e-mail i hasło ----------------------------
create or replace function public.dodaj_email(p_token uuid, p_email text, p_haslo text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_ja uuid := _sesja(p_token); v_email text := _email(p_email); v_u uzytkownicy;
begin
  if length(coalesce(p_haslo, '')) < 6 then raise exception 'Hasło jest za krótkie' using errcode = 'KN005'; end if;
  select * into v_u from uzytkownicy where id = v_ja;
  if v_u.email is not null then raise exception 'Konto ma już e-mail' using errcode = 'KN009'; end if;
  perform _email_wolny(v_email, v_ja);
  update uzytkownicy set email = v_email, haslo = crypt(p_haslo, gen_salt('bf')) where id = v_ja;
  return jsonb_build_object('nazwa', v_u.imie_nazwisko, 'admin', v_u.administrator, 'email', v_email);
end $$;

-- Niezalogowany właściciel starego konta (bez e-maila): imię i nazwisko + obecne hasło
-- (jeśli zostało już ustawione) → e-mail i nowe hasło. KN008 – trzeba podać obecne hasło.
create or replace function public.przenies_konto(p_nazwa text, p_haslo_obecne text, p_email text, p_haslo text, p_urzadzenie text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_email text := _email(p_email); v_u uzytkownicy;
begin
  if length(coalesce(p_haslo, '')) < 6 then raise exception 'Hasło jest za krótkie' using errcode = 'KN005'; end if;
  select * into v_u from uzytkownicy
   where lower(imie_nazwisko) = lower(_nazwa(p_nazwa)) and email is null
   order by ostatnia_aktywnosc desc limit 1;
  if v_u.id is null then
    if exists (select 1 from uzytkownicy where lower(imie_nazwisko) = lower(_nazwa(p_nazwa))) then
      raise exception 'To konto ma już e-mail' using errcode = 'KN009';
    end if;
    raise exception 'Nie ma takiego konta' using errcode = 'KN001';
  end if;
  if v_u.haslo is not null then
    if coalesce(p_haslo_obecne, '') = '' then raise exception 'Podaj obecne hasło' using errcode = 'KN008'; end if;
    if v_u.haslo <> crypt(p_haslo_obecne, v_u.haslo) then
      perform pg_sleep(1);
      raise exception 'Nieprawidłowe hasło' using errcode = '28P01';
    end if;
  end if;
  perform _email_wolny(v_email, v_u.id);
  update uzytkownicy set email = v_email, haslo = crypt(p_haslo, gen_salt('bf')) where id = v_u.id;
  return _nowa_sesja(v_u.id, p_urzadzenie, true);
end $$;

-- Obecność – zwraca też e-mail (brak e-maila = przeglądarka pokazuje okienko) ---------
create or replace function public.zglos(p_token uuid, p_urzadzenie text, p_nowa_wizyta boolean) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token); v_u uzytkownicy;
begin
  update uzytkownicy set ostatnia_aktywnosc = now(),
         liczba_wejsc = liczba_wejsc + case when p_nowa_wizyta then 1 else 0 end,
         urzadzenie = coalesce(left(p_urzadzenie, 40), urzadzenie)
   where id = v_ja returning * into v_u;
  return jsonb_build_object('nazwa', v_u.imie_nazwisko, 'admin', v_u.administrator, 'email', v_u.email);
end $$;

-- Panel administratora – z e-mailem ------------------------------------------------
create function public.lista_uzytkownikow(p_token uuid)
returns table (
  publiczne_id uuid, imie_nazwisko text, email text, pierwsze_wejscie timestamptz, ostatnia_aktywnosc timestamptz,
  liczba_wejsc integer, urzadzenie text, postep jsonb, postep_aktualizacja timestamptz,
  ma_haslo boolean, administrator boolean
)
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  return query
    select u.publiczne_id, u.imie_nazwisko, u.email, u.pierwsze_wejscie, u.ostatnia_aktywnosc, u.liczba_wejsc, u.urzadzenie,
           u.postep, u.postep_aktualizacja, u.haslo is not null, u.administrator
      from uzytkownicy u order by u.ostatnia_aktywnosc desc;
end $$;

-- Łączenie kont – zachowuje e-mail ----------------------------------------------------
create or replace function public.admin_polacz_konta(p_token uuid, p_zostaje uuid, p_usuwane uuid) returns boolean
language plpgsql security definer set search_path = public
as $$
declare a uzytkownicy; b uzytkownicy;
begin
  perform _admin(p_token);
  select * into a from uzytkownicy where publiczne_id = p_zostaje;
  select * into b from uzytkownicy where publiczne_id = p_usuwane;
  if a.id is null or b.id is null or a.id = b.id then raise exception 'Nieprawidłowe konta'; end if;
  if b.administrator then raise exception 'Nie można usunąć konta administratora'; end if;

  delete from znajomi where (od = a.id and do_kogo = b.id) or (od = b.id and do_kogo = a.id);
  update znajomi y set status = 'znajomi'
   where y.status = 'oczekuje' and (y.od = a.id or y.do_kogo = a.id)
     and exists (select 1 from znajomi z where z.status = 'znajomi'
                   and ((z.od = b.id and z.do_kogo = case when y.od = a.id then y.do_kogo else y.od end)
                     or (z.do_kogo = b.id and z.od = case when y.od = a.id then y.do_kogo else y.od end)));
  update znajomi z set od = a.id where z.od = b.id
     and not exists (select 1 from znajomi y where (y.od = a.id and y.do_kogo = z.do_kogo) or (y.od = z.do_kogo and y.do_kogo = a.id));
  update znajomi z set do_kogo = a.id where z.do_kogo = b.id
     and not exists (select 1 from znajomi y where (y.od = a.id and y.do_kogo = z.od) or (y.od = z.od and y.do_kogo = a.id));

  update sesje set uzytkownik = a.id where uzytkownik = b.id;   -- zalogowani na starym koncie są teraz na nowym
  delete from uzytkownicy where id = b.id;   -- najpierw usuwamy b, żeby jego e-mail mógł przejść na a
  update uzytkownicy set
    pierwsze_wejscie    = least(a.pierwsze_wejscie, b.pierwsze_wejscie),
    ostatnia_aktywnosc  = greatest(a.ostatnia_aktywnosc, b.ostatnia_aktywnosc),
    liczba_wejsc        = a.liczba_wejsc + b.liczba_wejsc,
    haslo               = case when a.email is null and b.email is not null then b.haslo else coalesce(a.haslo, b.haslo) end,
    email               = coalesce(a.email, b.email),
    postep              = case when _opanowane(b.postep) > _opanowane(a.postep) then b.postep else a.postep end,
    postep_aktualizacja = case when _opanowane(b.postep) > _opanowane(a.postep) then b.postep_aktualizacja else a.postep_aktualizacja end
   where id = a.id;
  return true;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'zaloz_konto(text, text, text, text)', 'zaloguj(text, text, text)', 'ustaw_haslo(text, text, text)',
    'dodaj_email(uuid, text, text)', 'przenies_konto(text, text, text, text, text)',
    'zglos(uuid, text, boolean)', 'lista_uzytkownikow(uuid)', 'admin_polacz_konta(uuid, uuid, uuid)']
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
