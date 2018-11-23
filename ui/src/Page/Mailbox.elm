module Page.Mailbox exposing (Model, Msg, init, load, subscriptions, update, view)

import Data.Message as Message exposing (Message)
import Data.MessageHeader as MessageHeader exposing (MessageHeader)
import Data.Session as Session exposing (Session)
import DateFormat as DF
import DateFormat.Relative as Relative
import Html exposing (..)
import Html.Attributes
    exposing
        ( class
        , classList
        , download
        , href
        , id
        , placeholder
        , property
        , target
        , type_
        , value
        )
import Html.Events exposing (..)
import Http exposing (Error)
import HttpUtil
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Ports
import Route
import Task
import Time exposing (Posix)



-- MODEL


type Body
    = TextBody
    | SafeHtmlBody


type State
    = LoadingList (Maybe MessageID)
    | ShowingList MessageList MessageState


type MessageState
    = NoMessage
    | LoadingMessage
    | ShowingMessage VisibleMessage
    | Transitioning VisibleMessage


type alias MessageID =
    String


type alias MessageList =
    { headers : List MessageHeader
    , selected : Maybe MessageID
    , searchFilter : String
    }


type alias VisibleMessage =
    { message : Message
    , markSeenAt : Maybe Int
    }


type alias Model =
    { mailboxName : String
    , state : State
    , bodyMode : Body
    , searchInput : String
    , now : Posix
    }


init : String -> Maybe MessageID -> ( Model, Cmd Msg, Session.Msg )
init mailboxName selection =
    ( Model mailboxName (LoadingList selection) SafeHtmlBody "" (Time.millisToPosix 0)
    , load mailboxName
    , Session.none
    )


load : String -> Cmd Msg
load mailboxName =
    Cmd.batch
        [ Task.perform Tick Time.now
        , getList mailboxName
        ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        subSeen =
            case model.state of
                ShowingList _ (ShowingMessage { message }) ->
                    if message.seen then
                        Sub.none

                    else
                        Time.every 250 MarkSeenTick

                _ ->
                    Sub.none
    in
    Sub.batch
        [ Time.every (30 * 1000) Tick
        , subSeen
        ]



-- UPDATE


type Msg
    = ListLoaded (Result Http.Error (List MessageHeader))
    | ClickMessage MessageID
    | OpenMessage MessageID
    | MessageLoaded (Result Http.Error Message)
    | MessageBody Body
    | OpenedTime Posix
    | MarkSeenTick Posix
    | MarkedSeen (Result Http.Error ())
    | DeleteMessage Message
    | DeletedMessage (Result Http.Error ())
    | PurgeMailbox
    | PurgedMailbox (Result Http.Error ())
    | OnSearchInput String
    | Tick Posix


update : Session -> Msg -> Model -> ( Model, Cmd Msg, Session.Msg )
update session msg model =
    case msg of
        ClickMessage id ->
            ( updateSelected model id
            , Cmd.batch
                [ -- Update browser location.
                  Route.newUrl session.key (Route.Message model.mailboxName id)
                , getMessage model.mailboxName id
                ]
            , Session.DisableRouting
            )

        OpenMessage id ->
            updateOpenMessage session model id

        DeleteMessage message ->
            updateDeleteMessage model message

        DeletedMessage (Ok _) ->
            ( model, Cmd.none, Session.none )

        DeletedMessage (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        ListLoaded (Ok headers) ->
            case model.state of
                LoadingList selection ->
                    let
                        newModel =
                            { model
                                | state = ShowingList (MessageList headers Nothing "") NoMessage
                            }
                    in
                    case selection of
                        Just id ->
                            updateOpenMessage session newModel id

                        Nothing ->
                            ( newModel, Cmd.none, Session.AddRecent model.mailboxName )

                _ ->
                    ( model, Cmd.none, Session.none )

        ListLoaded (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MarkedSeen (Ok _) ->
            ( model, Cmd.none, Session.none )

        MarkedSeen (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MessageLoaded (Ok message) ->
            updateMessageResult model message

        MessageLoaded (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MessageBody bodyMode ->
            ( { model | bodyMode = bodyMode }, Cmd.none, Session.none )

        OnSearchInput searchInput ->
            updateSearchInput model searchInput

        OpenedTime time ->
            case model.state of
                ShowingList list (ShowingMessage visible) ->
                    if visible.message.seen then
                        ( model, Cmd.none, Session.none )

                    else
                        -- Set 1500ms delay before reporting message as seen to backend.
                        let
                            markSeenAt =
                                Time.posixToMillis time + 1500
                        in
                        ( { model
                            | state =
                                ShowingList list
                                    (ShowingMessage
                                        { visible
                                            | markSeenAt = Just markSeenAt
                                        }
                                    )
                          }
                        , Cmd.none
                        , Session.none
                        )

                _ ->
                    ( model, Cmd.none, Session.none )

        PurgeMailbox ->
            updatePurge model

        PurgedMailbox (Ok _) ->
            ( model, Cmd.none, Session.none )

        PurgedMailbox (Err err) ->
            ( model, Cmd.none, Session.SetFlash (HttpUtil.errorString err) )

        MarkSeenTick now ->
            case model.state of
                ShowingList _ (ShowingMessage { message, markSeenAt }) ->
                    case markSeenAt of
                        Just deadline ->
                            if Time.posixToMillis now >= deadline then
                                updateMarkMessageSeen model message

                            else
                                ( model, Cmd.none, Session.none )

                        Nothing ->
                            ( model, Cmd.none, Session.none )

                _ ->
                    ( model, Cmd.none, Session.none )

        Tick now ->
            ( { model | now = now }, Cmd.none, Session.none )


{-| Replace the currently displayed message.
-}
updateMessageResult : Model -> Message -> ( Model, Cmd Msg, Session.Msg )
updateMessageResult model message =
    let
        bodyMode =
            if message.html == "" then
                TextBody

            else
                model.bodyMode
    in
    case model.state of
        LoadingList _ ->
            ( model, Cmd.none, Session.none )

        ShowingList list _ ->
            ( { model
                | state =
                    ShowingList
                        { list | selected = Just message.id }
                        (ShowingMessage (VisibleMessage message Nothing))
                , bodyMode = bodyMode
              }
            , Task.perform OpenedTime Time.now
            , Session.none
            )


updatePurge : Model -> ( Model, Cmd Msg, Session.Msg )
updatePurge model =
    let
        cmd =
            "/api/v1/mailbox/"
                ++ model.mailboxName
                |> HttpUtil.delete PurgedMailbox
    in
    case model.state of
        ShowingList list _ ->
            ( { model | state = ShowingList (MessageList [] Nothing "") NoMessage }
            , cmd
            , Session.none
            )

        _ ->
            ( model, cmd, Session.none )


updateSearchInput : Model -> String -> ( Model, Cmd Msg, Session.Msg )
updateSearchInput model searchInput =
    let
        searchFilter =
            if String.length searchInput > 1 then
                String.toLower searchInput

            else
                ""
    in
    case model.state of
        LoadingList _ ->
            ( model, Cmd.none, Session.none )

        ShowingList list messageState ->
            ( { model
                | searchInput = searchInput
                , state = ShowingList { list | searchFilter = searchFilter } messageState
              }
            , Cmd.none
            , Session.none
            )


{-| Set the selected message in our model.
-}
updateSelected : Model -> MessageID -> Model
updateSelected model id =
    case model.state of
        LoadingList _ ->
            model

        ShowingList list messageState ->
            let
                newList =
                    { list | selected = Just id }
            in
            case messageState of
                NoMessage ->
                    { model | state = ShowingList newList LoadingMessage }

                LoadingMessage ->
                    { model | state = ShowingList newList LoadingMessage }

                ShowingMessage visible ->
                    -- Use Transitioning state to prevent blank message flicker.
                    { model | state = ShowingList newList (Transitioning visible) }

                Transitioning visible ->
                    { model | state = ShowingList newList (Transitioning visible) }


updateDeleteMessage : Model -> Message -> ( Model, Cmd Msg, Session.Msg )
updateDeleteMessage model message =
    let
        url =
            "/api/v1/mailbox/" ++ message.mailbox ++ "/" ++ message.id

        cmd =
            HttpUtil.delete DeletedMessage url

        filter f messageList =
            { messageList | headers = List.filter f messageList.headers }
    in
    case model.state of
        ShowingList list _ ->
            ( { model
                | state =
                    ShowingList (filter (\x -> x.id /= message.id) list) NoMessage
              }
            , cmd
            , Session.none
            )

        _ ->
            ( model, cmd, Session.none )


updateMarkMessageSeen : Model -> Message -> ( Model, Cmd Msg, Session.Msg )
updateMarkMessageSeen model message =
    case model.state of
        ShowingList list (ShowingMessage visible) ->
            let
                updateSeen header =
                    if header.id == message.id then
                        { header | seen = True }

                    else
                        header

                url =
                    "/api/v1/mailbox/" ++ message.mailbox ++ "/" ++ message.id

                command =
                    -- The URL tells the API what message to update, so we only need to indicate the
                    -- desired change in the body.
                    Encode.object [ ( "seen", Encode.bool True ) ]
                        |> Http.jsonBody
                        |> HttpUtil.patch MarkedSeen url

                map f messageList =
                    { messageList | headers = List.map f messageList.headers }
            in
            ( { model
                | state =
                    ShowingList (map updateSeen list)
                        (ShowingMessage
                            { visible
                                | message = { message | seen = True }
                                , markSeenAt = Nothing
                            }
                        )
              }
            , command
            , Session.None
            )

        _ ->
            ( model, Cmd.none, Session.none )


updateOpenMessage : Session -> Model -> String -> ( Model, Cmd Msg, Session.Msg )
updateOpenMessage session model id =
    ( updateSelected model id
    , getMessage model.mailboxName id
    , Session.AddRecent model.mailboxName
    )


getList : String -> Cmd Msg
getList mailboxName =
    let
        url =
            "/api/v1/mailbox/" ++ mailboxName
    in
    Http.get
        { url = url
        , expect = Http.expectJson ListLoaded (Decode.list MessageHeader.decoder)
        }


getMessage : String -> MessageID -> Cmd Msg
getMessage mailboxName id =
    let
        url =
            "/serve/m/" ++ mailboxName ++ "/" ++ id
    in
    Http.get
        { url = url
        , expect = Http.expectJson MessageLoaded Message.decoder
        }



-- VIEW


view : Session -> Model -> { title : String, content : Html Msg }
view session model =
    { title = model.mailboxName ++ " - Inbucket"
    , content =
        div [ id "page", class "mailbox" ]
            [ viewMessageList session model
            , main_
                [ id "message" ]
                [ case model.state of
                    ShowingList _ NoMessage ->
                        text
                            ("Select a message on the left,"
                                ++ " or enter a different username into the box on upper right."
                            )

                    ShowingList _ (ShowingMessage { message }) ->
                        viewMessage message model.bodyMode

                    ShowingList _ (Transitioning { message }) ->
                        viewMessage message model.bodyMode

                    _ ->
                        text ""
                ]
            ]
    }


viewMessageList : Session -> Model -> Html Msg
viewMessageList session model =
    aside [ id "message-list" ]
        [ div []
            [ input
                [ type_ "search"
                , placeholder "search"
                , onInput OnSearchInput
                , value model.searchInput
                ]
                []
            , button [ onClick PurgeMailbox ] [ text "Purge" ]
            ]
        , case model.state of
            LoadingList _ ->
                div [] []

            ShowingList list _ ->
                div []
                    (list
                        |> filterMessageList
                        |> List.reverse
                        |> List.map (messageChip model list.selected)
                    )
        ]


messageChip : Model -> Maybe MessageID -> MessageHeader -> Html Msg
messageChip model selected message =
    div
        [ classList
            [ ( "message-list-entry", True )
            , ( "selected", selected == Just message.id )
            , ( "unseen", not message.seen )
            ]
        , onClick (ClickMessage message.id)
        ]
        [ div [ class "subject" ] [ text message.subject ]
        , div [ class "from" ] [ text message.from ]
        , div [ class "date" ] [ relativeDate model message.date ]
        ]


viewMessage : Message -> Body -> Html Msg
viewMessage message bodyMode =
    let
        sourceUrl =
            "/serve/m/" ++ message.mailbox ++ "/" ++ message.id ++ "/source"
    in
    div []
        [ div [ class "button-bar" ]
            [ button [ class "danger", onClick (DeleteMessage message) ] [ text "Delete" ]
            , a
                [ href sourceUrl, target "_blank" ]
                [ button [] [ text "Source" ] ]
            ]
        , dl [ id "message-header" ]
            [ dt [] [ text "From:" ]
            , dd [] [ text message.from ]
            , dt [] [ text "To:" ]
            , dd [] (List.map text message.to)
            , dt [] [ text "Date:" ]
            , dd [] [ verboseDate message.date ]
            , dt [] [ text "Subject:" ]
            , dd [] [ text message.subject ]
            ]
        , messageBody message bodyMode
        , attachments message
        ]


messageBody : Message -> Body -> Html Msg
messageBody message bodyMode =
    let
        bodyModeTab mode label =
            a
                [ classList [ ( "active", bodyMode == mode ) ]
                , onClick (MessageBody mode)
                , href "javacript:void(0)"
                ]
                [ text label ]

        safeHtml =
            bodyModeTab SafeHtmlBody "Safe HTML"

        plainText =
            bodyModeTab TextBody "Plain Text"

        tabs =
            if message.html == "" then
                [ plainText ]

            else
                [ safeHtml, plainText ]
    in
    div [ class "tab-panel" ]
        [ nav [ class "tab-bar" ] tabs
        , article [ class "message-body" ]
            [ case bodyMode of
                SafeHtmlBody ->
                    Html.node "rendered-html" [ property "content" (Encode.string message.html) ] []

                TextBody ->
                    Html.node "rendered-html" [ property "content" (Encode.string message.text) ] []
            ]
        ]


attachments : Message -> Html Msg
attachments message =
    let
        baseUrl =
            "/serve/m/attach/" ++ message.mailbox ++ "/" ++ message.id ++ "/"
    in
    if List.isEmpty message.attachments then
        div [] []

    else
        table [ class "attachments well" ] (List.map (attachmentRow baseUrl) message.attachments)


attachmentRow : String -> Message.Attachment -> Html Msg
attachmentRow baseUrl attach =
    let
        url =
            baseUrl ++ attach.id ++ "/" ++ attach.fileName
    in
    tr []
        [ td []
            [ a [ href url, target "_blank" ] [ text attach.fileName ]
            , text (" (" ++ attach.contentType ++ ") ")
            ]
        , td [] [ a [ href url, download attach.fileName, class "button" ] [ text "Download" ] ]
        ]


relativeDate : Model -> Posix -> Html Msg
relativeDate model date =
    Relative.relativeTime model.now date |> text


verboseDate : Posix -> Html Msg
verboseDate date =
    text <|
        DF.format
            [ DF.monthNameFull
            , DF.text " "
            , DF.dayOfMonthSuffix
            , DF.text ", "
            , DF.yearNumber
            , DF.text " "
            , DF.hourNumber
            , DF.text ":"
            , DF.minuteFixed
            , DF.text ":"
            , DF.secondFixed
            , DF.text " "
            , DF.amPmUppercase
            ]
            Time.utc
            date



-- UTILITY


filterMessageList : MessageList -> List MessageHeader
filterMessageList list =
    if list.searchFilter == "" then
        list.headers

    else
        let
            matches header =
                String.contains list.searchFilter (String.toLower header.subject)
                    || String.contains list.searchFilter (String.toLower header.from)
        in
        List.filter matches list.headers