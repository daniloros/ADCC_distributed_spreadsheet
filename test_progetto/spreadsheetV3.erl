-module(spreadsheetV3).
-author("daniros").


-record(cell, {id, row, column, value={primitive, undef}}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[]}).


%% API
-export([init/0, start/0, populate_cell/2, create_sheet/4]).


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

create_sheet(Name, SheetName, NumRows, NumColumns) ->
  {atomic, CellIds} = mnesia:transaction(fun() -> populate_cell(NumRows, NumColumns) end),
  io:format("CellIds ~p\n", [CellIds]),
  F = fun() ->
    SheetPage = #sheet_page{name = SheetName, cells_ids = CellIds},
    mnesia:write(SheetPage),
    Sheet = #sheet{name = Name, sheet_page_ids = [SheetName]},
    mnesia:write(Sheet)
      end,
  {atomic, Val} = mnesia:transaction(F),
  Val
.

populate_cell(NumRows, NumColumns) ->
  Rows = lists:seq(1, NumRows),
  Columns = lists:seq(1, NumColumns),
  CellIds = lists:foldl(
    fun(Row, Acc) ->
%%      io:format("Acc Righe: ~p\n", [Acc]),
      lists:foldl(
        fun(Column, Acc2) ->
%%          io:format("Acc Colonne: ~p\n", [Acc2]),
          Cell = #cell{
            id = {Row, Column},
            row = Row,
            column = Column,
            value = "A"
          },
          mnesia:write(Cell),
          [Cell#cell.id | Acc2]
        end,
        [], Columns) ++ Acc
    end,
    [], Rows),
%%  io:format("CellIds: ~p\n", [CellIds]),
  lists:reverse(CellIds).


%%% CREATO FILE EXCEL, AVRA' UN NOME, UN TAB NOMINATO E LE CELLE
%%% ORA CAPIRE COME ASSEGNARGLI PIU TAB, PERCHè AL MOMENTO NE PRENDE SOLO UNO