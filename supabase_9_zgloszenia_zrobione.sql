-- =====================================================================
--  Aktualizacja 9: powiadomienie dla autora, gdy zgłoszenie jest „zrobione”
--  Wymaga aktualizacji 8.
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej.
--
--  • Gdy administrator kliknie „✓ Zrobione”, zapisuje się chwila załatwienia.
--  • Autor zgłoszenia pobiera swoje załatwione karty (z ostatnich 60 dni)
--    i dostaje powiadomienie pod dzwonkiem.
--  • Karty oznaczone jako zrobione przed tą aktualizacją nie wywołują powiadomień.
-- =====================================================================

alter table public.zgloszenia add column if not exists zrobione timestamptz;

create or replace function public.admin_zgloszenie_status(p_token uuid, p_id bigint, p_status text) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  if p_status not in ('nowe', 'przeczytane', 'zrobione') then raise exception 'Nieznany status'; end if;
  update zgloszenia
     set zrobione = case when p_status <> 'zrobione' then null
                         when status = 'zrobione' then coalesce(zrobione, now())
                         else now() end,
         status = p_status
   where id = p_id;
  return found;
end $$;

-- Załatwione zgłoszenia zalogowanego użytkownika -----------------------------------
create or replace function public.moje_zrobione_zgloszenia(p_token uuid)
returns table (id bigint, rodzaj text, tresc text, zrobione timestamptz)
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token);
begin
  return query
    select z.id, z.rodzaj, left(z.tresc, 200), z.zrobione
      from zgloszenia z
     where z.uzytkownik = v_ja and z.status = 'zrobione' and z.zrobione > now() - interval '60 days'
     order by z.zrobione desc
     limit 20;
end $$;

revoke all on function public.moje_zrobione_zgloszenia(uuid) from public;
grant execute on function public.moje_zrobione_zgloszenia(uuid) to anon, authenticated;
