-module(spreadsheetv8).
-author("daniros").


-record(cell, {id, row, column, value}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[], owner_pid, access_policies=[]}).


%% API
-export([init/0, start/0, populate_cell/4, new/1, new/4, share/2, get_sheet/1]).


init() ->
  mnesia:create_schema([node()]),
  mnesia:start(),
  create_tables(),
  mnesia:stop()
.

create_tables() ->
  mnesia:create_table(cell, [{attributes, record_info(fields, cell)}]),
  mnesia:create_table(sheet_page, [{attributes, record_info(fields, sheet_page)}]),
  mnesia:create_table(sheet, [{attributes, record_info(fields, sheet)}])
.

start() ->
  mnesia:start(),
  mnesia:wait_for_tables([sheet,sheet_page,cell], 20000)
.


new(Name) ->
  new(Name, 3, 6, 1)
.
%%%-------------------------------------------------------------------
%%% L'idea è avere una struttura fatta in questo modo:
%%% #sheet:
%%%   #sheet_page (TAB):
%%%     #celle
%%%  #sheet_page (TAB):
%%%     #celle

%%% Quindi come prima cosa creo le celle. Ogni cella dovrà avere un id differente
%%%   e questo id lo userò come riferimento per collegarlo ai Tab
%%% Ogni tab quindi conterrà il riferimento alle celle e dovrà avere un id univoco,
%%%   l'id lo userò come riferimento per collegarlo al foglio
%%% Infine creo il foglio con il suo nome e conterrà il riferimento ai sui tab
%%%-------------------------------------------------------------------
new(Name, N, M, K) ->
  case sheet_alredy_exists(Name) of
    {atomic,true} ->
      {error, 'sheet alredy exists'};
    {atomic,false} ->
      try
        {atomic, CellIds} = mnesia:transaction(fun() -> populate_cell(Name, K, N, M) end),
        %%  io:format("CellIds ~p\n", [CellIds]),
        F = fun() ->
          populate_sheet_page(Name, K, CellIds),
          SheetPageRef = lists:seq(1,K),
          Sheet = #sheet{name = Name, sheet_page_ids = SheetPageRef, owner_pid = self()},
          mnesia:write(Sheet)
            end,
        {atomic, Val} = mnesia:transaction(F),
        {ok, Val}
      catch
        _:Reason -> {error, Reason}
      end
  end
.

populate_cell(NameSheet, NumSheetPage, NumRows, NumColumns) ->
  Rows = lists:seq(1, NumRows),
  Columns = lists:seq(1, NumColumns),
  SheetPageNumber = lists:seq(1,NumSheetPage),
  CellIds = lists:foldl(
    fun(Sheet, Acc) ->
      PageName = lists:concat([atom_to_list(NameSheet), integer_to_list(Sheet)]),
      SheetCellIds = lists:foldl(
        fun(Row, AccRows) ->
          RowCellIds = lists:foldl(
            fun(Column, AccColumns) ->
              Cell = #cell{
                id = {PageName, Row, Column},
                row = Row,
                column = Column,
                value = undefined
              },
              mnesia:write(Cell),
              [Cell#cell.id | AccColumns]
            end,
            [], Columns),
          RowCellIds ++ AccRows
        end,
        [], Rows),
      SheetCellIds ++ Acc
    end,
    [], SheetPageNumber),
  lists:reverse(CellIds)
.


populate_sheet_page(SheetPageNumber, NumberSheetPage, RefCell) ->
  Number = lists:seq(1, NumberSheetPage),
  lists:foreach(
    fun(K) ->
      PageName = lists:concat([atom_to_list(SheetPageNumber), integer_to_list(K)]),
      SheetPage = #sheet_page{name = PageName, cells_ids = RefCell},
      mnesia:write(SheetPage)
    end,
    Number)
.

sheet_alredy_exists(Name) ->
  F = fun() ->
    case mnesia:dirty_read({sheet, Name}) of
      [] -> false;
      _  -> true
    end
      end,
  mnesia:transaction(F)
.

get_sheet(SpreadsheetName) ->
  mnesia:dirty_read({sheet, SpreadsheetName})
.

share(SpreadsheetName, AccessPolicies) ->
  F = fun() ->
    case mnesia:dirty_read({sheet, SpreadsheetName}) of
      %% torna una lista di sheet
      [Sheet] ->
        io:format("Sheet ~p ", [Sheet]),
        NewSheet = Sheet#sheet{access_policies = AccessPolicies},
        mnesia:write(NewSheet),
        ok;
      [] ->
        {error, not_found}
    end
      end,
  mnesia:transaction(F)
.

%% problema con le celle risolto, cambiato l'id in {nometab,riga,colonna}
