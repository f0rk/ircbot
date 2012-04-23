-module(ircbot).
-compile([export_all]).

% for factoids
-record(data, {key, value}).

% at some point most of this should be config
-define(CRLF, "\r\n").
-define(NICK, "trubble").
-define(BOTHOST, "dummy-host").
-define(BOTSERVER, "dummy-server").
-define(BOTNAME, "Test Bot").
-define(CHANNELS, ["#truveris"]).

start_link(Host, Port) ->
    spawn_link(?MODULE, connect, [Host, Port]).

connect(Host, Port) ->
    {A1,A2,A3} = now(),
    random:seed(A1, A2, A3),
    inets:start(),
    Options = [binary, {active, false}, {packet, 0}],
    {ok, Sock} = gen_tcp:connect(Host, Port, Options),
    init(Sock),
    loop(Sock).

send(Sock, Text) when is_binary(Text) ->
    send(Sock, binary_to_list(Text));

send(Sock, Text) ->
    gen_tcp:send(Sock, list_to_binary(Text ++ ?CRLF)).

init(Sock) ->
    create_db(),
    send(Sock, "USER " ++ ?NICK ++ " " ++ ?BOTHOST ++ " " ++ ?BOTSERVER ++ " :" ++ ?BOTNAME),
    send(Sock, "NICK " ++ ?NICK),
    lists:map(fun(Channel) -> send(Sock, "JOIN " ++ Channel) end, ?CHANNELS).

loop(Sock) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, Data} ->
            case handle(Data) of
                {ok, Answer} ->
                    send(Sock, Answer),
                    loop(Sock);
                ignore ->
                    loop(Sock);
                quit ->
                    quit(Sock),
                    ok
            end;
        {error, closed} ->
            io:format("sock ~w closed [~w]~n", [Sock, self()]),
            ok
    end.

strip_crlf(Data) ->
    [Line|_] = re:split(Data, ?CRLF),
    binary_to_list(Line).

handle(Data) ->
    Str = strip_crlf(binary_to_list(Data)),
    respond(parse(Str)).

parse(Str) ->
    Actions = [
        {ping, "^PING :(\\S+)"},
        {privmsg, "^:(\\S+)!(\\S+)@(\\S+)\\sPRIVMSG\\s([\#\&]?\\S+)\\s:(.*)"}
    ],
    parser(Str, Actions).

parser(Str, [{Action, Regex}|Rest]) ->
    RegexOpts = [{capture, all_but_first, list}],
    case re:run(Str, Regex, RegexOpts) of
        {match, Captures} ->
            {Action, Captures};
        _ ->
            parser(Str, Rest)
    end;

parser(_, []) ->
    nomatch.

respond({ping, [Reply]}) ->
    {ok, "PONG :" ++ Reply};

respond({privmsg, [Nick, User, Host, Chan, Msg]}) ->
    privmsg(Nick, User, Host, Chan, Msg);

respond(_) ->
    ignore.

privmsg(Nick, User, Host, Chan, Msg) ->
    case re:run(Msg, "^" ++ ?NICK ++ "[:,] (.*)", [{capture, all_but_first, list}]) of
        {match, [Capture]} -> % directly addressed
            privmsg_direct(Nick, User, Host, Chan, Capture);
        _ -> % forever alone
            privmsg_indirect(Nick, User, Host, Chan, Msg)
    end.

privmsg_direct(Nick, User, Host, Chan, Msg) ->
    case re:run(Msg, "^(forget|clock|date|time|maxim|excuse|literal)(?: )?(.*)?", [{capture, all_but_first, list}]) of
        {match, [Action, Args]} ->
            case Action of
                "forget" ->
                    privmsg_forget_factoid(Nick, User, Host, Chan, Args);
                "clock" ->
                    {_,{Hour,Minutes,Seconds}} = erlang:localtime(),
                    {ok, "PRIVMSG " ++ Chan ++ lists:flatten(io_lib:format(" :~2.10.0B:~2.10.0B:~2.10.0B", [Hour, Minutes, Seconds]))};
                "date" ->
                    {Date={Year,Month,Day},Time={Hour,Minutes,Seconds}} = erlang:localtime(),
                    DayOfWeek = calendar:day_of_the_week(Date),
                    DayName = httpd_util:day(DayOfWeek),
                    MonthName = httpd_util:month(Month),
                    {ok, "PRIVMSG " ++ Chan ++ lists:flatten(io_lib:format(" :~s, ~2.10.0B ~s ~4.10.0B", [DayName, Day, MonthName, Year]))};
                "time" ->
                    {Mega, Secs, _} = now(),
                    UnixTime = Mega * 1000000 + Secs,
                    {ok, "PRIVMSG " ++ Chan ++ " :" ++ integer_to_list(UnixTime)};
                "maxim" ->
                    {ok, "PRIVMSG " ++ Chan ++ " :" ++ maxim()};
                "excuse" ->
                    {ok, "PRIVMSG " ++ Chan ++ " :" ++ excuse()};
                "literal" ->
                    CleanMsg = re:replace(Args, "(\\?|!)+$", "", [{return, list}]),
                    case retrieve(string:to_lower(CleanMsg)) of
                        [Oid] ->
                            {ok, "PRIVMSG " ++ Chan ++ " :literal " ++ CleanMsg ++ " =is= " ++ Oid#data.value};
                        _ ->
                            {ok, "PRIVMSG " ++ Chan ++ " :no matches for that, " ++ Nick}
                    end;
                _ ->
                    {ok, "PRIVMSG " ++ Chan ++ " :I don't know how to do that, " ++ Nick}
            end;
        _ ->
            case re:run(Msg, "(.*?) (is also|is|are also|are) (.*)", [{capture, all_but_first, list}]) of
                {match, [Fact, Kind, Capture]} -> % set factoid
                    case Kind of
                        "is" ->
                            privmsg_is(Nick, User, Host, Chan, Fact, Capture);
                        "is also" ->
                            privmsg_isalso(Nick, User, Host, Chan, Fact, Capture);
                        "are" ->
                            privmsg_is(Nick, User, Host, Chan, Fact, Capture);
                        "are also" ->
                            privmsg_isalso(Nick, User, Host, Chan, Fact, Capture)
                    end;
                _ -> % retrieve factoid
                    privmsg_get_factoid(Nick, User, Host, Chan, Msg, direct)
            end
    end.

privmsg_is(Nick, User, Host, Chan, Fact, Msg) ->
    Key = string:to_lower(Fact),
    case exists(Key) of
        true ->
            [Oid] = retrieve(Key),
            {ok, "PRIVMSG " ++ Chan ++ " :but " ++ Fact ++ " is " ++ Oid#data.value};
        _ ->
            privmsg_set_factoid(Nick, User, Host, Chan, Fact, Msg)
    end.

privmsg_isalso(Nick, User, Host, Chan, Fact, Msg) ->
    Key = string:to_lower(Fact),
    case retrieve(Key) of
        [Oid] ->
            case re:run(Msg, "^\\s*\\|") of
                nomatch ->
                    privmsg_set_factoid(Nick, User, Host, Chan, Fact, Oid#data.value ++ " or " ++ Msg);
                _ ->
                    privmsg_set_factoid(Nick, User, Host, Chan, Fact, Oid#data.value ++ Msg)
            end;
        [] ->
            privmsg_set_factoid(Nick, User, Host, Chan, Fact, Msg)
    end.

privmsg_set_factoid(Nick, User, Host, Chan, Fact, Msg) ->
    case check_factoid_length(Msg) of
        true ->
            insert(string:to_lower(Fact), Msg),
            {ok, "PRIVMSG " ++ Chan ++ " :ok"};
        _ ->
            {ok, "PRIVMSG " ++ Chan ++ " :I'm sorry " ++ Nick ++ ", but that's too long."}
    end.

check_factoid_length(Msg) ->
    Length = string:len(Msg),
    if
        Length > 400 ->
            false;
        true ->
            true
    end.

privmsg_get_factoid(Nick, User, Host, Chan, Msg, Direct) ->
    StripMsg = re:replace(Msg, "[[:cntrl:]]ACTION (.*)[[:cntrl:]]", "\\1", [{return, list}]),
    CleanMsg = re:replace(StripMsg, "(\\?|!)+$", "", [{return, list}]),
    case retrieve(CleanMsg) of
        [Oid] ->
            Part = privmsg_get_factoid_part(Oid#data.value),
            Rss = case re:run(Part, "<rss (.*?)>", [{capture, all_but_first, list}]) of
                nomatch ->
                    Part;
                {match, [Address]} ->
                    re:replace(Part, "<rss " ++ Address ++ ">", rss(Address), [{return, list}])
            end,
            Expanded = re:replace(Rss, "\\$who(\\s|$)", Nick ++ "\\1"),
            case re:run(Expanded, "^\\s*(<reply>|<action>)", [{capture, all_but_first, list}]) of
                nomatch ->
                    case Direct of
                        direct ->
                            {ok, "PRIVMSG " ++ Chan ++ " :it has been said that " ++ CleanMsg ++ " is "  ++ Expanded};
                        _ ->
                            ignore
                    end;
                {match, [Kind]} ->
                    case Kind of
                        "<reply>" ->
                            WithoutReply = re:replace(Expanded, "^\\s*<reply>", "", [{return, list}]),
                            {ok, "PRIVMSG " ++ Chan ++ " :" ++ WithoutReply};
                        "<action>" ->
                            WithoutAction = re:replace(Expanded, "^\\s*<action>", "", [{return, list}]),
                            {ok, "PRIVMSG " ++ Chan ++ " :" ++ [1] ++ "ACTION " ++ WithoutAction ++ [1]}
                    end
            end;
        _ ->
            case Direct of
                direct ->
                    {ok, "PRIVMSG " ++ Chan ++ " :I haven't a clue, " ++ Nick};
                _ ->
                    ignore
            end
    end.

privmsg_get_factoid_part(Msg) ->
    Parts = re:split(Msg, "(?<!\\\\)\\|", [{return, list}]),
    Part = lists:nth(random:uniform(length(Parts)), Parts),
    re:replace(Part, "\\\\\\|", "|", [{return, list}]).

privmsg_forget_factoid(Nick, User, Host, Chan, Fact) ->
    case exists(Fact) of
        true ->
            remove(Fact),
            {ok, "PRIVMSG " ++ Chan ++ " :I forgot " ++ Fact};
        _ ->
            {ok, "PRIVMSG " ++ Chan ++ " :I already had it like that, " ++ Nick}
    end.

privmsg_indirect(Nick, User, Host, Chan, Msg) ->
    privmsg_get_factoid(Nick, User, Host, Chan, Msg, indirect).

quit(Sock) ->
    send(Sock, "QUIT :Peace out."),
    gen_tcp:close(Sock).

rss(Address) ->
    case httpc:request(get, {Address, []}, [], []) of
        {ok, {Status, Headers, Body}} ->
            case re:run(Body, "<item>.*<title>(.*?)</title>.*</item>", [dotall, {capture, all_but_first, list}]) of
                {match, [Ret]} ->
                    re:replace(Ret, "\\r?\\n", " ", [{return, list}]);
                _ ->
                    "there was a problem fetching from " ++ Address ++ " (no match of data)"
            end;
        _ ->
            "there was a problem fetching from " ++ Address ++ " (request failed)"
    end.

maxim() -> % return a random maxim
    Maxims = [
        "You cannot just paste code with no understanding of what is going on and expect it to work.",
        "You can't just make shit up and expect the computer to know what you mean, Retardo!",
        "You said it didn't work, but you didn't say what it would have done if it *had* worked.",
        "What are you really trying to accomplish here?",
        "Who the fuck cares which one is faster?",
        "Now is the time in our program where you look at the manual.",
        "Look at the error message!  Look at the error message!",
        "Looking for a compiler bug is the strategy of LAST resort.  LAST resort.",
        "Premature optimization is the root of all evil.",
        "Bad programmer!  No cookie!",
        "I see you omitted $! from the error message.   It won't tell you what went wrong if you don't ask it to.",
        "You wrote the same thing twice here.  The cardinal rule of programming is that you never ever write the same thing twice.",
        "Evidently it's important to you to get the wrong answer as quickly as possible.",
        "Gee, I don't know.  I wonder what the manual says about that?",
        "Well, no duh.  That's because you ignored the error message, dimwit.",
        "Only Sherlock Holmes can debug the program by pure deduction from the output.  You are not Sherlock Holmes.  Run the fucking debugger already.",
        "Always ignore the second error message unless the meaning is obvious.",
        "Read.  Learn.  Evolve.",
        "Well, then get one that *does* do auto-indent.  You can't do good work with bad tools.",
        "No.  You must believe the ERROR MESSAGE.  You MUST believe the error message.",
        "The error message is the Truth.  The error message is God.  ",
        "It could be anything.  Too bad you didn't bother to diagnose the error, huh?",
        "You don't suppress error messages, you dumbass, you PAY ATTENTION and try to understand them.",
        "Never catch a signal except as a last resort.",
        "Well, if you don't know what it does, why did you put it in your program?",
        "Gosh, that wasn't very bright, was it?",
        "That's like taking a crap on someone's doorstep and then ringing the doorbell to ask for toilet paper.",
        "A good approach to that problem would be to hire a computer programmer.",
        "First get a book on programming.  Then read it.  Then write the program.",
        "First ask yourself `How would I do this without a computer?'  Then have the computer do it the same way.",
        "Would you like to see my rate card?",
        "I think you are asking the wrong question here.",
        "Holy cow.",
        "Because it's a syntax error.",
        "Because this is Perl, not C.",
        "Because this is Perl, not Lisp.",
        "Because that's the way it is.",
        "Because.",
        "If you have `some weird error', the problem is probably with your frobnitzer.",
        "Because the computer cannot read your mind.  Guess what?  I cannot read your mind *either*.",
        "You said `It doesn't work'.  The next violation will be punished by death.",
        "Of course it doesn't work!  That's because you don't know what you are doing!",
        "Sure, but you have to have some understanding also.",
        "Ah yes, and you are the first person to have noticed this bug since 1987.  Sure.",
        "Yes, that's what it's supposed to do when you say that.",
        "Well, what did you expect?",
        "Perhaps you have forgotten that this is an engineering discipline, not some sort of black magic.",
        "You know, this sort of thing is amenable to experimental observation.",
        "Perhaps your veeblefitzer is clogged.",
        "What happens when you try?",
        "Now you are just being superstitious.  ",
        "Your question has exceeded the system limit for pronouns in a single sentence.  Please dereference and try again.",
        "In my experience that is a bad strategy, because the people who ask such questions are the ones who paste the answer into their program without understanding it and then complain that it `does not work'.",
        "Of course, this is a heuristic, which is a fancy way of saying that it doesn't work.",
        "If your function is written correctly, it will handle an empty array the same way as a nonempty array.",
        "When in doubt, use brute force.",
        "Well, it might be more intuitive that way, but it would also be useless.",
        "Show the code.",
        "The bug is in you, not in Perl.",
        "Cargo-cult.",
        "So you threw in some random punctuation for no particular reason, and then you didn't get the result you expected.  Hmmmm.",
        "How should I know what is wrong when I haven't even seen the code?  I am not clairvoyant.",
        "How should I know how to do what you want when you didn't say what you wanted to do?",
        "It's easy to get the *wrong* answer in O(1) time.",
        "I guess this just goes to show that you can lead a horse to water, but you can't make him drink it.",
        "You are a stupid asshole.  Shut the fuck up."
    ],
    lists:nth(random:uniform(length(Maxims)), Maxims).

excuse() ->
    Excuses = [
        "clock speed",
        "solar flares",
        "electromagnetic radiation from satellite debris",
        "static from nylon underwear",
        "static from plastic slide rules",
        "global warming",
        "poor power conditioning",
        "static buildup",
        "doppler effect",
        "hardware stress fractures",
        "magnetic interference from money/credit cards",
        "dry joints on cable plug",
        "we're waiting for [the phone company] to fix that line",
        "sounds like a Windows problem, try calling Microsoft support",
        "temporary routing anomaly",
        "somebody was calculating pi on the server",
        "fat electrons in the lines",
        "excess surge protection",
        "floating point processor overflow",
        "divide-by-zero error",
        "POSIX compliance problem",
        "monitor resolution too high",
        "improperly oriented keyboard",
        "network packets travelling uphill (use a carrier pigeon)",
        "Decreasing electron flux",
        "first Saturday after first full moon in Winter",
        "radiosity depletion",
        "CPU radiator broken",
        "It works the way the Wang did, what's the problem",
        "positron router malfunction",
        "cellular telephone interference",
        "techtonic stress",
        "piezo-electric interference",
        "(l)user error",
        "working as designed",
        "dynamic software linking table corrupted",
        "heavy gravity fluctuation, move computer to floor rapidly",
        "secretary plugged hairdryer into UPS",
        "terrorist activities",
        "not enough memory, go get system upgrade",
        "interrupt configuration error",
        "spaghetti cable cause packet failure",
        "boss forgot system password",
        "bank holiday - system operating credits  not recharged",
        "virus attack, luser responsible",
        "waste water tank overflowed onto computer",
        "Complete Transient Lockout",
        "bad ether in the cables",
        "Bogon emissions",
        "Change in Earth's rotational speed",
        "Cosmic ray particles crashed through the hard disk platter",
        "Smell from unhygienic janitorial staff wrecked the tape heads",
        "Little hamster in running wheel had coronary; waiting for replacement to be Fedexed from Wyoming",
        "Evil dogs hypnotised the night shift",
        "Plumber mistook routing panel for decorative wall fixture",
        "Electricians made popcorn in the power supply",
        "Groundskeepers stole the root password",
        "high pressure system failure",
        "failed trials, system needs redesigned",
        "system has been recalled",
        "not approved by the FCC",
        "need to wrap system in aluminum foil to fix problem",
        "not properly grounded, please bury computer",
        "CPU needs recalibration",
        "system needs to be rebooted",
        "bit bucket overflow",
        "descramble code needed from software company",
        "only available on a need to know basis",
        "knot in cables caused data stream to become twisted and kinked",
        "nesting roaches shorted out the ether cable",
        "The file system is full of it",
        "Satan did it",
        "Daemons did it",
        "You're out of memory",
        "There isn't any problem",
        "Unoptimized hard drive",
        "Typo in the code",
        "Yes, yes, its called a design limitation",
        "Look, buddy:  Windows 3.1 IS A General Protection Fault.",
        "That's a great computer you have there; have you considered how it would work as a BSD machine?",
        "Please excuse me, I have to circuit an AC line through my head to get this database working.",
        "Yeah, yo mama dresses you funny and you need a mouse to delete files.",
        "Support staff hung over, send aspirin and come back LATER.",
        "Someone is standing on the ethernet cable, causing a kink in the cable",
        "Windows 95 undocumented \"feature\"",
        "Runt packets",
        "Password is too complex to decrypt",
        "Boss' kid fucked up the machine",
        "Electromagnetic energy loss",
        "Budget cuts",
        "Mouse chewed through power cable",
        "Stale file handle (next time use Tupperware(tm)!)",
        "Feature not yet implemented",
        "Internet outage",
        "Pentium FDIV bug",
        "Vendor no longer supports the product",
        "Small animal kamikaze attack on power supplies",
        "The vendor put the bug there.",
        "SIMM crosstalk.",
        "IRQ dropout",
        "Collapsed Backbone",
        "Power company testing new voltage spike (creation) equipment",
        "operators on strike due to broken coffee machine",
        "backup tape overwritten with copy of system manager's favourite CD",
        "UPS interrupted the server's power",
        "The electrician didn't know what the yellow cable was so he yanked the ethernet out.",
        "The keyboard isn't plugged in",
        "The air conditioning water supply pipe ruptured over the machine room",
        "The electricity substation in the car park blew up.",
        "The rolling stones concert down the road caused a brown out",
        "The salesman drove over the CPU board.",
        "The monitor is plugged into the serial port",
        "Root nameservers are out of sync",
        "electro-magnetic pulses from French above ground nuke testing.",
        "your keyboard's space bar is generating spurious keycodes.",
        "the real ttys became pseudo ttys and vice-versa.",
        "the printer thinks its a router.",
        "the router thinks its a printer.",
        "evil hackers from Serbia.",
        "we just switched to FDDI.",
        "halon system went off and killed the operators.",
        "because Bill Gates is a Jehovah's witness and so nothing can work on St. Swithin's day.",
        "user to computer ratio too high.",
        "user to computer ration too low.",
        "we just switched to Sprint.",
        "it has Intel Inside",
        "Sticky bits on disk.",
        "Power Company having EMP problems with their reactor",
        "The ring needs another token",
        "new management",
        "telnet: Unable to connect to remote host: Connection refused",
        "SCSI Chain overterminated",
        "It's not plugged in.",
        "because of network lag due to too many people playing deathmatch",
        "You put the disk in upside down.",
        "Daemons loose in system.",
        "User was distributing pornography on server; system seized by FBI.",
        "BNC (brain not connected)",
        "UBNC (user brain not connected)",
        "LBNC (luser brain not connected)",
        "disks spinning backwards - toggle the hemisphere jumper.",
        "new guy cross-connected phone lines with ac power bus.",
        "had to use hammer to free stuck disk drive heads.",
        "Too few computrons available.",
        "Flat tire on station wagon with tapes.  (\"Never underestimate the bandwidth of a station wagon full of tapes hurling down the highway\" Andrew S. Tannenbaum) ",
        "Communications satellite used by the military for star wars.",
        "Party-bug in the Aloha protocol.",
        "Insert coin for new game",
        "Dew on the telephone lines.",
        "Arcserve crashed the server again.",
        "Some one needed the powerstrip, so they pulled the switch plug.",
        "My pony-tail hit the on/off switch on the power strip.",
        "Big to little endian conversion error",
        "You can tune a file system, but you can't tune a fish (from most tunefs man pages)",
        "Dumb terminal",
        "Zombie processes haunting the computer",
        "Incorrect time synchronization",
        "Defunct processes",
        "Stubborn processes",
        "non-redundant fan failure ",
        "monitor VLF leakage",
        "bugs in the RAID",
        "no \"any\" key on keyboard",
        "root rot",
        "Backbone Scoliosis",
        "/pub/lunch",
        "excessive collisions & not enough packet ambulances",
        "le0: no carrier: transceiver cable problem?",
        "broadcast packets on wrong frequency",
        "popper unable to process jumbo kernel",
        "NOTICE: alloc: /dev/null: filesystem full",
        "pseudo-user on a pseudo-terminal",
        "Recursive traversal of loopback mount points",
        "Backbone adjustment",
        "OS swapped to disk",
        "vapors from evaporating sticky-note adhesives",
        "sticktion",
        "short leg on process table",
        "multicasts on broken packets",
        "ether leak",
        "Atilla the Hub",
        "endothermal recalibration",
        "filesystem not big enough for Jumbo Kernel Patch",
        "loop found in loop in redundant loopback",
        "system consumed all the paper for paging",
        "permission denied",
        "Reformatting Page. Wait...",
        "..disk or the processor is on fire.",
        "SCSI's too wide.",
        "Proprietary Information.",
        "Just type 'mv * /dev/null'.",
        "runaway cat on system.",
        "Did you pay the new Support Fee?",
        "We only support a 1200 bps connection.",
        "We only support a 28000 bps connection.",
        "Me no internet, only janitor, me just wax floors.",
        "I'm sorry a pentium won't do, you need an SGI to connect with us.",
        "Post-it Note Sludge leaked into the monitor.",
        "the curls in your keyboard cord are losing electricity.",
        "The monitor needs another box of pixels.",
        "RPC_PMAP_FAILURE",
        "kernel panic: write-only-memory (/dev/wom0) capacity exceeded.",
        "Write-only-memory subsystem too slow for this machine. Contact your local dealer.",
        "Just pick up the phone and give modem connect sounds. \"Well you said we should get more lines so we don't have voice lines.\"",
        "Quantum dynamics are affecting the transistors",
        "Police are examining all internet packets in the search for a narco-net-trafficker",
        "We are currently trying a new concept of using a live mouse.  Unfortunately, one has yet to survive being hooked up to the computer.....please bear with us.",
        "Your mail is being routed through Germany ... and they're censoring us.",
        "Only people with names beginning with 'A' are getting mail this week (a la Microsoft)",
        "We didn't pay the Internet bill and it's been cut off.",
        "Lightning strikes.",
        "Of course it doesn't work. We've performed a software upgrade.",
        "Change your language to Finnish.",
        "Fluorescent lights are generating negative ions. If turning them off doesn't work, take them out and put tin foil on the ends.",
        "High nuclear activity in your area.",
        "What office are you in? Oh, that one.  Did you know that your building was built over the universities first nuclear research site? And wow, aren't you the lucky one, your office is right over where the core is buried!",
        "The MGs ran out of gas.",
        "The UPS doesn't have a battery backup.",
        "Recursivity.  Call back if it happens again.",
        "Someone thought The Big Red Button was a light switch.",
        "The mainframe needs to rest.  It's getting old, you know.",
        "I'm not sure.  Try calling the Internet's head office -- it's in the book.",
        "The lines are all busy (busied out, that is -- why let them in to begin with?).",
        "Jan  9 16:41:27 huber su: 'su root' succeeded for .... on /dev/pts/1",
        "It's those computer people in X {city of world}.  They keep stuffing things up.",
        "A star wars satellite accidently blew up the WAN.",
        "Fatal error right in front of screen",
        "That function is not currently supported, but Bill Gates assures us it will be featured in the next upgrade.",
        "wrong polarity of neutron flow",
        "Lusers learning curve appears to be fractal",
        "We had to turn off that service to comply with the CDA Bill.",
        "Ionization from the air-conditioning",
        "TCP/IP UDP alarm threshold is set too low.",
        "Someone is broadcasting pygmy packets and the router doesn't know how to deal with them.",
        "The new frame relay network hasn't bedded down the software loop transmitter yet. ",
        "Fanout dropping voltage too much, try cutting some of those little traces",
        "Plate voltage too low on demodulator tube",
        "You did wha... oh _dear_....",
        "CPU needs bearings repacked",
        "Too many little pins on CPU confusing it, bend back and forth until 10-20% are neatly removed. Do _not_ leave metal bits visible!",
        "_Rosin_ core solder? But...",
        "Software uses US measurements, but the OS is in metric...",
        "The computer fletely, mouse and all.",
        "Your cat tried to eat the mouse.",
        "The Borg tried to assimilate your system. Resistance is futile.",
        "It must have been the lightning storm we had (yesterday) (last week) (last month)",
        "Due to Federal Budget problems we have been forced to cut back on the number of users able to access the system at one time. (namely none allowed....)",
        "Too much radiation coming from the soil.",
        "Unfortunately we have run out of bits/bytes/whatever. Don't worry, the next supply will be coming next week.",
        "Program load too heavy for processor to lift.",
        "Processes running slowly due to weak power supply",
        "Our ISP is having {switching,routing,SMDS,frame relay} problems",
        "We've run out of licenses",
        "Interference from lunar radiation",
        "Standing room only on the bus.",
        "You need to install an RTFM interface.",
        "That would be because the software doesn't work.",
        "That's easy to fix, but I can't be bothered.",
        "Someone's tie is caught in the printer, and if anything else gets printed, he'll be in it too.",
        "We're upgrading /dev/null",
        "The Usenet news is out of date",
        "Our POP server was kidnapped by a weasel.",
        "It's stuck in the Web.",
        "Your modem doesn't speak English.",
        "The mouse escaped.",
        "All of the packets are empty.",
        "The UPS is on strike.",
        "Neutrino overload on the nameserver",
        "Melting hard drives",
        "Someone has messed up the kernel pointers",
        "The kernel license has expired",
        "Netscape has crashed",
        "The cord jumped over and hit the power switch.",
        "It was OK before you touched it.",
        "Bit rot",
        "U.S. Postal Service",
        "Your Flux Capacitor has gone bad.",
        "The Dilithium Crystals need to be rotated.",
        "The static electricity routing is acting up...",
        "Traceroute says that there is a routing problem in the backbone.  It's not our problem.",
        "The co-locator cannot verify the frame-relay gateway to the ISDN server.",
        "High altitude condensation from U.S.A.F prototype aircraft has contaminated the primary subnet mask. Turn off your computer for 9 days to avoid damaging it.",
        "Lawn mower blade in your fan need sharpening",
        "Electrons on a bender",
        "Telecommunications is upgrading. ",
        "Telecommunications is downgrading.",
        "Telecommunications is downshifting.",
        "Hard drive sleeping. Let it wake up on it's own...",
        "Interference between the keyboard and the chair.",
        "The CPU has shifted, and become decentralized.",
        "Due to the CDA, we no longer have a root account.",
        "We ran out of dial tone and we're and waiting for the phone company to deliver another bottle.",
        "You must've hit the wrong any key.",
        "PCMCIA slave driver",
        "The Token fell out of the ring. Call us when you find it.",
        "The hardware bus needs a new token.",
        "Too many interrupts",
        "Not enough interrupts",
        "The data on your hard drive is out of balance.",
        "Digital Manipulator exceeding velocity parameters",
        "appears to be a Slow/Narrow SCSI-0 Interface problem",
        "microelectronic Riemannian curved-space fault in write-only file system",
        "fractal radiation jamming the backbone",
        "routing problems on the neural net",
        "IRQ-problems with the Un-Interruptible-Power-Supply",
        "CPU-angle has to be adjusted because of vibrations coming from the nearby road",
        "emissions from GSM-phones",
        "CD-ROM server needs recalibration",
        "firewall needs cooling",
        "asynchronous inode failure",
        "transient bus protocol violation",
        "incompatible bit-registration operators",
        "your process is not ISO 9000 compliant",
        "You need to upgrade your VESA local bus to a MasterCard local bus.",
        "The recent proliferation of Nuclear Testing",
        "Elves on strike. (Why do they call EMAG Elf Magic)",
        "Internet exceeded Luser level, please wait until a luser logs off before attempting to log back on.",
        "Your EMAIL is now being delivered by the USPS.",
        "Your computer hasn't been returning all the bits it gets from the Internet.",
        "You've been infected by the Telescoping Hubble virus.",
        "Scheduled global CPU outage",
        "Your Pentium has a heating problem - try cooling it with ice cold water.(Do not turn of your computer, you do not want to cool down the Pentium Chip while he isn't working, do you?)",
        "Your processor has processed too many instructions.  Turn it off immediately, do not type any commands!!",
        "Your packets were eaten by the terminator",
        "Your processor does not develop enough heat.",
        "We need a licensed electrician to replace the light bulbs in the computer room.",
        "The POP server is out of Coke",
        "Fiber optics caused gas main leak",
        "Server depressed, needs Prozac",
        "quantum decoherence",
        "those damn raccoons!",
        "suboptimal routing experience",
        "A plumber is needed, the network drain is clogged",
        "50% of the manual is in .pdf readme files",
        "the AA battery in the wallclock sends magnetic interference",
        "the xy axis in the trackball is coordinated with the summer solstice",
        "the butane lighter causes the pincushioning",
        "old inkjet cartridges emanate barium-based fumes",
        "manager in the cable duct",
        "Well fix that in the next (upgrade, update, patch release, service pack).",
        "HTTPD Error 666 : BOFH was here",
        "HTTPD Error 4004 : very old Intel cpu - insufficient processing power",
        "The ATM board has run out of 10 pound notes.  We are having a whip round to refill it, care to contribute ?",
        "Network failure -  call NBC",
        "Having to manually track the satellite.",
        "Your/our computer(s) had suffered a memory leak, and we are waiting for them to be topped up.",
        "The rubber band broke",
        "We're on Token Ring, and it looks like the token got loose.",
        "Stray Alpha Particles from memory packaging caused Hard Memory Error on Server.",
        "paradigm shift...without a clutch",
        "PEBKAC (Problem Exists Between Keyboard And Chair)",
        "The cables are not the same length.",
        "Second-system effect.",
        "Chewing gum on /dev/sd3c",
        "Boredom in the Kernel.",
        "the daemons! the daemons! the terrible daemons!",
        "I'd love to help you -- it's just that the Boss won't let me near the computer. ",
        "struck by the Good Times virus",
        "YOU HAVE AN I/O ERROR -> Incompetent Operator error",
        "Your parity check is overdrawn and you're out of cache.",
        "Communist revolutionaries taking over the server room and demanding all the computers in the building or they shoot the sysadmin. Poor misguided fools.",
        "Plasma conduit breach",
        "Out of cards on drive D:",
        "Sand fleas eating the Internet cables",
        "parallel processors running perpendicular today",
        "ATM cell has no roaming feature turned on, notebooks can't connect",
        "Webmasters kidnapped by evil cult.",
        "Failure to adjust for daylight savings time.",
        "Virus transmitted from computer to sysadmins.",
        "Virus due to computers having unsafe sex.",
        "Incorrectly configured static routes on the corerouters.",
        "Forced to support NT servers; sysadmins quit.",
        "Suspicious pointer corrupted virtual machine",
        "It's the InterNIC's fault.",
        "Root name servers corrupted.",
        "Budget cuts forced us to sell all the power cords for the servers.",
        "Someone hooked the twisted pair wires into the answering machine.",
        "Operators killed by year 2000 bug bite.",
        "We've picked COBOL as the language of choice.",
        "Operators killed when huge stack of backup tapes fell over.",
        "Robotic tape changer mistook operator's tie for a backup tape.",
        "Someone was smoking in the computer room and set off the halon systems.",
        "Your processor has taken a ride to Heaven's Gate on the UFO behind Hale-Bopp's comet.",
        "it's an ID-10-T error",
        "Dyslexics retyping hosts file on servers",
        "The Internet is being scanned for viruses.",
        "Your computer's union contract is set to expire at midnight.",
        "Bad user karma.",
        "/dev/clue was linked to /dev/null",
        "Increased sunspot activity.",
        "We already sent around a notice about that.",
        "It's union rules. There's nothing we can do about it. Sorry.",
        "Interference from the Van Allen Belt.",
        "Jupiter is aligned with Mars.",
        "Redundant ACLs. ",
        "Mail server hit by UniSpammer.",
        "T-1's congested due to porn traffic to the news server.",
        "Data for intranet got routed through the extranet and landed on the internet.",
        "We are a 100% Microsoft Shop.",
        "We are Microsoft.  What you are experiencing is not a problem; it is an undocumented feature.",
        "Sales staff sold a product we don't offer.",
        "Secretary sent chain letter to all 5000 employees.",
        "Sysadmin didn't hear pager go off due to loud music from bar-room speakers.",
        "Sysadmin accidentally destroyed pager with a large hammer.",
        "Sysadmins unavailable because they are in a meeting talking about why they are unavailable so much.",
        "Bad cafeteria food landed all the sysadmins in the hospital.",
        "Route flapping at the NAP.",
        "Computers under water due to SYN flooding.",
        "The vulcan-death-grip ping has been applied.",
        "Electrical conduits in machine room are melting.",
        "Traffic jam on the Information Superhighway.",
        "Radial Telemetry Infiltration",
        "Cow-tippers tipped a cow onto the server.",
        "tachyon emissions overloading the system",
        "Maintenance window broken",
        "We're out of slots on the server",
        "Computer room being moved.  Our systems are down for the weekend.",
        "Sysadmins busy fighting SPAM.",
        "Repeated reboots of the system failed to solve problem",
        "Feature was not beta tested",
        "Domain controller not responding",
        "Someone else stole your IP address, call the Internet detectives!",
        "It's not RFC-822 compliant.",
        "operation failed because: there is no message for this error (#1014)",
        "stop bit received",
        "internet is needed to catch the etherbunny",
        "network down, IP packets delivered via UPS",
        "Firmware update in the coffee machine",
        "Temporal anomaly",
        "Mouse has out-of-cheese-error",
        "Borg implants are failing",
        "Borg nanites have infested the server",
        "error: one bad user found in front of screen",
        "Please state the nature of the technical emergency",
        "Internet shut down due to maintenance",
        "Daemon escaped from pentagram",
        "crop circles in the corn shell",
        "sticky bit has come loose",
        "Hot Java has gone cold",
        "Cache miss - please take better aim next time",
        "Hash table has woodworm",
        "Trojan horse ran out of hay",
        "Zombie processes detected, machine is haunted.",
        "overflow error in /dev/null",
        "Browser's cookie is corrupted -- someone's been nibbling on it.",
        "Mailer-daemon is busy burning your message in hell.",
        "According to Microsoft, it's by design",
        "vi needs to be upgraded to vii",
        "greenpeace free'd the mallocs",
        "Terrorists crashed an airplane into the server room, have to remove /bin/laden. (rm -rf /bin/laden)",
        "astropneumatic oscillations in the water-cooling",
        "Somebody ran the operating system through a spelling checker.",
        "Rhythmic variations in the voltage reaching the power supply.",
        "Wardrobe malfunction during the halftime performance."
    ],
    lists:nth(random:uniform(length(Excuses)), Excuses).

% factoid store/retrieve
create_db() ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    mnesia:create_table(data, [{disc_copies, [node()]}, {attributes, record_info(fields, data)}]).

insert(Key, Val) ->
    Record = #data{key=Key, value=Val},
    mnesia:transaction(
        fun() ->
            mnesia:write(Record)
        end
    ).

retrieve(Key) ->
    {atomic, Data} = mnesia:transaction(
        fun() ->
            mnesia:read({data, Key})
        end
    ),
    Data.

exists(Key) ->
    case retrieve(Key) of
        [] ->
            false;
        _ ->
            true
    end.

remove(Key) ->
    case retrieve(Key) of
        [Record] ->
            mnesia:transaction(
                fun() ->
                    mnesia:delete_object(Record)
                end
            );
        _ ->
            ok
    end.

