-- =====================================================================
--  Aktualizacja 7: postęp nauki zapisany na koncie
--  Wymaga aktualizacji 5 i 6.
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej.
--
--  stan        – pełny stan nauki z przeglądarki (porcje, pudełka, statystyki, kalendarz…)
--  stan_wersja – rośnie przy każdym zapisie; chroni przed nadpisaniem postępu
--                z innego urządzenia (zapis podaje wersję, na której bazował)
-- =====================================================================

alter table public.uzytkownicy add column if not exists stan jsonb;
alter table public.uzytkownicy add column if not exists stan_wersja integer not null default 0;

create or replace function public.pobierz_stan(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token); v_u uzytkownicy;
begin
  select * into v_u from uzytkownicy where id = v_ja;
  return jsonb_build_object('wersja', v_u.stan_wersja, 'stan', v_u.stan);
end $$;

-- Zapis stanu. Jeśli w bazie jest nowsza wersja niż p_bazowa (zapis z innego urządzenia),
-- nic nie zmienia i zwraca { konflikt: true, wersja, stan } – przeglądarka sama decyduje,
-- czy przyjąć stan z bazy, czy wysłać swój ponownie z p_wymus = true.
create or replace function public.zapisz_stan(p_token uuid, p_stan jsonb, p_postep jsonb, p_bazowa integer, p_wymus boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token); v_u uzytkownicy;
begin
  if p_stan is null or jsonb_typeof(p_stan) <> 'object' or pg_column_size(p_stan) > 2000000 then
    raise exception 'Nieprawidłowe dane postępu';
  end if;
  if p_postep is not null and (jsonb_typeof(p_postep) <> 'object' or pg_column_size(p_postep) > 60000) then
    raise exception 'Nieprawidłowe dane postępu';
  end if;
  select * into v_u from uzytkownicy where id = v_ja for update;
  if not coalesce(p_wymus, false) and v_u.stan_wersja <> coalesce(p_bazowa, 0) then
    return jsonb_build_object('konflikt', true, 'wersja', v_u.stan_wersja, 'stan', v_u.stan);
  end if;
  update uzytkownicy set
    stan = p_stan, stan_wersja = stan_wersja + 1,
    postep = coalesce(p_postep, postep),
    postep_aktualizacja = case when p_postep is null then postep_aktualizacja else now() end,
    ostatnia_aktywnosc = now()
   where id = v_ja returning stan_wersja into v_u.stan_wersja;
  return jsonb_build_object('wersja', v_u.stan_wersja);
end $$;

-- Łączenie kont – jak w aktualizacji 5, a dodatkowo przenosi pełny stan nauki
-- (razem z lepszym postępem).
create or replace function public.admin_polacz_konta(p_token uuid, p_zostaje uuid, p_usuwane uuid) returns boolean
language plpgsql security definer set search_path = public
as $$
declare a uzytkownicy; b uzytkownicy; v_b_lepszy boolean;
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

  update sesje set uzytkownik = a.id where uzytkownik = b.id;
  delete from uzytkownicy where id = b.id;   -- najpierw usuwamy b, żeby jego e-mail mógł przejść na a
  v_b_lepszy := _opanowane(b.postep) > _opanowane(a.postep) or (a.stan is null and b.stan is not null);
  update uzytkownicy set
    pierwsze_wejscie    = least(a.pierwsze_wejscie, b.pierwsze_wejscie),
    ostatnia_aktywnosc  = greatest(a.ostatnia_aktywnosc, b.ostatnia_aktywnosc),
    liczba_wejsc        = a.liczba_wejsc + b.liczba_wejsc,
    haslo               = case when a.email is null and b.email is not null then b.haslo else coalesce(a.haslo, b.haslo) end,
    email               = coalesce(a.email, b.email),
    postep              = case when v_b_lepszy then coalesce(b.postep, a.postep) else a.postep end,
    postep_aktualizacja = case when v_b_lepszy then coalesce(b.postep_aktualizacja, a.postep_aktualizacja) else a.postep_aktualizacja end,
    stan                = case when v_b_lepszy then coalesce(b.stan, a.stan) else coalesce(a.stan, b.stan) end,
    stan_wersja         = greatest(a.stan_wersja, b.stan_wersja) + 1   -- urządzenia pobiorą połączony stan
   where id = a.id;
  return true;
end $$;

revoke all on function public.pobierz_stan(uuid) from public;
revoke all on function public.zapisz_stan(uuid, jsonb, jsonb, integer, boolean) from public;
grant execute on function public.pobierz_stan(uuid) to anon, authenticated;
grant execute on function public.zapisz_stan(uuid, jsonb, jsonb, integer, boolean) to anon, authenticated;
