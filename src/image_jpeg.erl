%%% File    : image_jpg.erl
%%% Author  : Tony Rogvall <tony@bix.hemma.se>
%%% Description : JPG image processing (Exif/JPG files)
%%% Created :  5 Mar 2003 by Tony Rogvall <tony@bix.hemma.se>

-module(image_jpeg).

-include_lib("erl_img.hrl").

-include("jpeg.hrl").
-include("tiff.hrl").
-include("exif.hrl").

-include("api.hrl").
%% -define(debug, true).
-include("dbg.hrl").

%% YCbCr => RGB
-define(R(Y,Cb,Cr), (Y + (1.402)*((Cr)-128))).
-define(G(Y,Cb,Cr), (Y - 0.34414*((Cb)-128) - 0.71414*((Cr)-128))).
-define(B(Y,Cb,Cr), (Y + 1.772*(Cb-128))).

%% RGB => YCbCr
-define(Y(R,G,B), (0.299*(R) + 0.587*(G) + 0.114*(B))).
-define(Cb(R,G,B), (0.1687*(R) - 0.3313*(G) + 0.5*(B) + 128)).
-define(Cr(R,G,B), (0.5*R - 0.4187*(G) - 0.0813*(B) + 128)).



magic(<<?M_SOI:16,?M_APP1:16,_Len:16,"Exif",0,0,_/binary>>) -> true;
magic(<<?M_SOI:16,?M_JFIF:16,_Len:16,"JFIF",_,_,_/binary>>) -> true;
magic(<<?M_SOI:16,?M_DQT:16,_/binary>>) -> true;
magic(<<?M_SOI:16,?M_DHT:16,_/binary>>) -> true;
magic(<<?M_SOI:16,?M_SOF0:16,_/binary>>) -> true;
magic(<<?M_SOI:16,?M_SOS:16,_/binary>>) -> true;
magic(<<?M_SOI:16,?M_COM:16,_/binary>>) -> true;
magic(_) -> false.

mime_type() -> "image/jpeg".

extensions() -> [".jpeg", ".jpg"].


read_info(Fd) ->
    case file:read(Fd, 2) of
        {ok, <<?M_SOI:16>>} ->
            read_sections(Fd,
                          #erl_image { type = ?MODULE,
                                     order = upper_left
                                    });
        {ok,_} ->
            {error, bad_magic};
        Error -> Error
    end.

write_info(_Fd, _IMG) ->
    ok.


read(_Fd,IMG) ->
    {ok,IMG}.

read(_Fd,IMG,_RowFun,_St0) ->
    {ok,IMG}.

write(_Fd,_IMG) ->
    ok.


read_sections(Fd, IMG) ->
    case file:read(Fd, 4) of
        eof ->
            {ok,IMG};
        {ok,<<Marker:16,Len:16>>} ->
            read_section(Fd,Marker,Len-2,IMG);
        {ok,_} ->
            {error, bad_file};
        Error -> Error
    end.

read_section(Fd,Marker,Len,IMG) ->
    if Marker == ?M_SOS -> {ok,IMG};
       Marker == ?M_EOI -> {ok,IMG};
       Marker == ?M_COM ->
            case file:read(Fd, Len) of
                {ok,Bin} ->
                    read_sections(Fd, IMG#erl_image {comment=
                                                   binary_to_list(Bin)});
                _Error ->
                    {error, bad_file}
            end;
       Marker == ?M_APP1 ->
            case file:read(Fd, Len) of
                {ok,<<"Exif",0,0,Bin/binary>>} ->
                    read_sections(Fd, process_exif(Bin,IMG));
                {ok,_} ->
                    read_sections(Fd, IMG)
            end;
       Marker == ?M_DQT;
       Marker == ?M_SOF0;
       Marker == ?M_SOF1;
       Marker == ?M_SOF2;
       Marker == ?M_SOF3;
       Marker == ?M_DHT;
       Marker == ?M_SOF5;
       Marker == ?M_SOF6;
       Marker == ?M_SOF7;
       Marker == ?M_SOF9;
       Marker == ?M_SOF10;
       Marker == ?M_SOF11;
       Marker == ?M_SOF13;
       Marker == ?M_SOF14;
       Marker == ?M_SOF15 ->
            case file:read(Fd, Len) of
                {ok,Bin} ->
                    read_sections(Fd, process_sofn(Bin,IMG));
                Error ->
                    Error
            end;
       true ->
            file:position(Fd, {cur,Len}),
            read_sections(Fd, IMG)
    end.

process_sofn(<<Depth:8,Height:16,Width:16,_Components:8,_Bin/binary>>, IMG) ->
    IMG#erl_image { depth  = Depth,
                  height = Height,
                  width  = Width }.

collect_maker(_Fd, _T, St) ->
    {ok, St}.

collect_exif(Fd, T, St) ->
    _Key = exif:decode_tag(T#tiff_entry.tag),
    ?dbg("EXIF(~s) ~p ~p ~p\n",
        [T#tiff_entry.ifd,_Key,T#tiff_entry.type, T#tiff_entry.value]),
    case T#tiff_entry.tag of
        ?ExifInteroperabilityOffset ->
            [Offset] = T#tiff_entry.value,
            %% could be handle by a collect_interop?
            case image_tiff:scan_ifd(Fd, [$0,$.|T#tiff_entry.ifd],
                                     Offset, T#tiff_entry.endian,
                                     fun collect_exif/3, St) of
                {ok, St1} ->
                    St1;
                _Error ->
                    St
            end;
        ?MakerNote ->
            case collect_maker(Fd, T, St) of
                {ok,St1} ->
                    St1;
                _Error ->
                    St
            end;
        _ ->
            St
    end.


%% Image info collector functions
collect_tiff(Fd, T, St) ->
    Key = image_tiff:decode_tag(T#tiff_entry.tag),
    ?dbg("TIFF(~s) ~p ~p ~p\n",
        [T#tiff_entry.ifd,Key,T#tiff_entry.type, T#tiff_entry.value]),
    case T#tiff_entry.tag of
        ?ImageWidth ->
            [Width] = T#tiff_entry.value,
            St#erl_image { width = Width };
        ?ImageLength ->
            [Length] = T#tiff_entry.value,
            St#erl_image { height = Length };
        ?BitsPerSample ->
            Bs = T#tiff_entry.value,
            St#erl_image { depth = lists:sum(Bs) };
        ?ImageDescription ->
            [Value] = T#tiff_entry.value,
            St#erl_image { comment = Value };
        ?DateTime ->
            [Value] = T#tiff_entry.value,
            case string:tokens(Value, ": ") of
                [YYYY,MM,DD,H,M,S] ->
                    DateTime = {{list_to_integer(YYYY),
                                 list_to_integer(MM),
                                 list_to_integer(DD)},
                                {list_to_integer(H),
                                 list_to_integer(M),
                                 list_to_integer(S)}},
                    St#erl_image { itime = DateTime};
                _ ->
                    St
            end;
        ?ExifOffset ->
            [Offset] = T#tiff_entry.value,
            case image_tiff:scan_ifd(Fd, [$0,$.|T#tiff_entry.ifd],
                                     Offset, T#tiff_entry.endian,
                                     fun collect_exif/3, St) of
                {ok, St1} ->
                    St1;
                _Error ->
                    St
            end;
        _ ->
            Value = T#tiff_entry.value,
            As = St#erl_image.attributes,
            St#erl_image { attributes = [{Key,Value}|As]}
    end.

process_exif(Bin, IMG) ->
    case image_tiff:scan_binary(Bin, fun collect_tiff/3, IMG) of
        {ok, IMG1} ->
            IMG1;
        _Error ->
            IMG
    end.
