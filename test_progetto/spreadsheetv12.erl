-module(spreadsheetv12).
-author("daniros").


-record(cell, {id, row, column, value}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[], owner_pid, access_policies=[]}).



%% API
-export([init/0, start/0, populate_cell/4, new/1, new/4, share/2, get_sheet/1,
  set_cell_value/5, get_cell_value/4, get_all_cell_values/1, to_csv/1]).


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
  new(Name, 6, 3, 1)
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
      {error, 'sheet already exists'};
    {atomic,false} ->
      try
        {atomic, CellIds} = mnesia:transaction(fun() -> populate_cell(Name, K, M, N) end),
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
%%                value = undefined
                value = rand:uniform(100)
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
%%  io:format("RefCell ~p\n", [RefCell]),
  Number = lists:seq(1, NumberSheetPage),
  lists:foreach(
    fun(K) ->
      PageName = lists:concat([atom_to_list(SheetPageNumber), integer_to_list(K)]),
      %% filtro poichè devo inserire solo le celle che riferiscono al TAB di interessa
      %% altrimenti ogni tab avrebbe il riferimento a tutte le celle anche di altre tab
      PageCellIds = lists:filter(
        fun(Cell) ->
          case Cell of
            %% se inizia con il PageName che mi interessa allora true
            {PageName, _, _} -> true;
            _ -> false
          end
        end,
        RefCell),
%%      io:format("RefCell ~p\n", [PageCellIds]),
      SheetPage = #sheet_page{name = PageName, cells_ids = PageCellIds},
%%      io:format("SheetPage ~p\n", [SheetPage]),
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
        OldPolicies = Sheet#sheet.access_policies,
        NewSheet = Sheet#sheet{access_policies = OldPolicies ++ AccessPolicies},
        mnesia:write(NewSheet),
        ok;
      [] ->
        {error, not_found}
    end
      end,
  mnesia:transaction(F)
.

%% TODO: Da aggiungere controllo errori
get_cell_value(Name,Tab,Row,Column) ->
  PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  [Cell] = mnesia:dirty_read(cell, {PageName,Row,Column}),
  io:format("Valore: ~p \n", [Cell#cell.value])
.


%%% TODO: Da Aggiungere controllo errori
set_cell_value(Name,Tab,Row,Column, Value) ->
  PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  F = fun() ->
    [Cell] = mnesia:read(cell, {PageName,Row,Column}),
    UpdateCell = Cell#cell{value = Value},
    mnesia:write(UpdateCell)
      end,
  {atomic, Val} = mnesia:transaction(F),
  Val
.

get_all_cell_values(SpreadsheetName) ->
  case get_sheet(SpreadsheetName) of
    [Sheet] ->
      SheetPages = Sheet#sheet.sheet_page_ids,
      [get_cell_values(SpreadsheetName, Page) || Page <- SheetPages];
    _ ->
      {error, not_found}
  end.

get_cell_values(SpreadsheetName, PageName) ->
  NewPageName = lists:concat([atom_to_list(SpreadsheetName), integer_to_list(PageName)]),
  case mnesia:dirty_read(sheet_page, NewPageName) of
    [{sheet_page, _, CellIds}] ->
%%      io:format("CellIds ~p\n", [CellIds]),

      %% prendo le righe per ogni cellIds %%
      RowNumbers = [Row || {_, Row, _} <- CellIds],
%%      io:format("RowsNumbers ~p\n", [RowNumbers]),

      %% elimino i duplicati %%
      Rows = lists:usort(RowNumbers),

%%      io:format("Rows ~p\n", [Rows]),
      [get_row_values(NewPageName, Row) || Row <- Rows];
    _ ->
      []
  end.

get_row_values(SpreadsheetName, Rows) ->
%%  io:format("PageName ~p\n", [PageName]),
%%  io:format("Row ~p\n", [Rows]),

  %% faccio la query per cercare tutte le righe %%
  RowCells = mnesia:dirty_match_object({cell, {SpreadsheetName, Rows, '_'}, '_', '_', '_'}),

%%  io:format("RowCells ~p\n", [RowCells]),
  [Value || #cell{value = Value} <- RowCells].


to_csv(SpreadsheetName) ->
  case get_all_cell_values(SpreadsheetName) of
    [Data] ->
      io:format("Data ~p\n", [Data]),
      CsvRows = lists:map(
          fun(Row) ->
%%            io:format("Row ~p\n", [Row]),
            %% per ogni row converto in intero le concateno separate da virgole e a fine riga vado a capo %%
            RowStrings = [integer_to_list(X) || X <- Row],
            CsvRow = string:join(RowStrings, ",") ++ "\n",
%%            io:format("CSVRow ~p\n", [CsvRow]),
            CsvRow
          end,
        Data),

      %% "appiattisco" le stringhe per scriverle nel .csv, passaggio necessario per il write_file %%
      CsvContent = lists:flatten(CsvRows),
%%      io:format("CSVContent ~p", [CsvContent]),
      StringSpreadsheetName = atom_to_list(SpreadsheetName),
      FilePath = StringSpreadsheetName ++ ".csv",
      file:write_file(FilePath, CsvContent),
      {ok, FilePath};
    {error, Reason} ->
      {error, Reason}
  end.


%%% creo correttamente il file .CSV
%%% il problema sta nel fatto che non è possibile farlo con un foglio che ha 2 tab
%%% per il momento capire ora come fare il contrario, quindi da CSV a riempiere una tabella di Mnesia
