# --
# Kernel/Modules/AgentBounce.pm - to bounce articles of tickets 
# Copyright (C) 2002 Martin Edenhofer <martin+code@otrs.org>
# --
# $Id: AgentBounce.pm,v 1.6 2002-09-10 23:20:36 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Kernel::Modules::AgentBounce;

use strict;

use vars qw($VERSION);
$VERSION = '$Revision: 1.6 $';
$VERSION =~ s/^.*:\s(\d+\.\d+)\s.*$/$1/;

# --
sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object    
    my $Self = {}; 
    bless ($Self, $Type);
    
    foreach (keys %Param) {
        $Self->{$_} = $Param{$_};
    }

    # check needed Opjects
    foreach (
      'ParamObject', 
      'DBObject', 
      'TicketObject', 
      'LayoutObject', 
      'LogObject', 
      'QueueObject', 
      'ConfigObject',
      'ArticleObject',
    ) {
        die "Got no $_!" if (!$Self->{$_});
    }

    $Self->{ArticleID} = $Self->{ParamObject}->GetParam(Param => 'ArticleID') || '';

    return $Self;
}
# --
sub Run {
    my $Self = shift;
    my %Param = @_;
    my $Output;
    my $NextScreen = $Self->{NextScreen} || '';
    my $BackScreen = $Self->{BackScreen};
    my $UserID = $Self->{UserID};
    my $UserLogin = $Self->{UserLogin};
    
    # --
    # check needed stuff
    # --
    foreach (qw(ArticleID TicketID QueueID)) {
        if (!$Self->{$_}) {
            $Output .= $Self->{LayoutObject}->Header(Title => 'Bounce');
            $Output .= $Self->{LayoutObject}->Error(
              Message => "$_ is needed!",
              Comment => 'Please contact your admin',
            );
            $Output .= $Self->{LayoutObject}->Footer();
            return $Output;
        }
    }
    # --
    # check permissions
    # --
    if (!$Self->{TicketObject}->Permission(
        TicketID => $Self->{TicketID},
        UserID => $Self->{UserID})) {
        # --
        # error screen, don't show ticket
        # --
        return $Self->{LayoutObject}->NoPermission(WithHeader => 'yes');
    }

    $Param{TicketNumber} = $Self->{TicketObject}->GetTNOfId(ID => $Self->{TicketID});
    $Param{QueueID} = $Self->{TicketObject}->GetQueueIDOfTicketID(TicketID => $Self->{TicketID});
    # --
    # prepare salutation
    # --
    my $QueueObject = Kernel::System::Queue->new(
        QueueID => $Param{QueueID},
        DBObject => $Self->{DBObject},
        ConfigObject => $Self->{ConfigObject},
        LogObject => $Self->{LogObject},
    );

    if ($Self->{Subaction} eq '' || !$Self->{Subaction}) {
        $Output .= $Self->{LayoutObject}->Header(Title => 'Bounce');
        # --
        # get lock state && permissions
        # --
        my $LockState = $Self->{TicketObject}->GetLockState(TicketID => $Self->{TicketID}) || 0;
        if (!$LockState) {
            # set owner
            $Self->{TicketObject}->SetOwner(
              TicketID => $Self->{TicketID},
              UserID => $UserID,
              NewUserID => $UserID,
            );
            # set lock
            if ($Self->{TicketObject}->SetLock(
              TicketID => $Self->{TicketID},
              Lock => 'lock',
              UserID => $UserID
            )) {
                # show lock state
                $Output .= $Self->{LayoutObject}->TicketLocked(TicketID => $Self->{TicketID});
            }
         }
        else {
            my ($OwnerID, $OwnerLogin) = $Self->{TicketObject}->CheckOwner(
              TicketID => $Self->{TicketID},
            );
  
            if ($OwnerID != $UserID) {
              $Output .= $Self->{LayoutObject}->Error(
                Message => "Sorry, the current owner is $OwnerLogin",
                Comment => 'Please change the owner first.',
              );
              $Output .= $Self->{LayoutObject}->Footer();
              return $Output;
            }
        }

        # --
        # get article data 
        # --
        my %Data = $Self->{ArticleObject}->GetArticle(
            ArticleID => $Self->{ArticleID},
        );
        # --
        # prepare subject ...
        # --
        my $TicketHook = $Self->{ConfigObject}->Get('TicketHook') || '';
        $Data{Subject} =~ s/\[$TicketHook: $Param{TicketNumber}\] //g;
        $Data{Subject} =~ s/^(.{30}).*$/$1 [...]/;
        $Data{Subject} = "[$TicketHook: $Param{TicketNumber}] RE: " . $Data{Subject};
        # --
        # prepare to (ReplyTo!) ...
        # --
        if ($Data{ReplyTo}) {
            $Data{To} = $Data{ReplyTo};
        }
        else {
            $Data{To} = $Data{From};
        }
        # --
        # prepare salutation
        # --
        $Param{Salutation} = $QueueObject->GetSalutation();
        # prepare customer realname
        if ($Param{Salutation} =~ /<OTRS_CUSTOMER_REALNAME>/) {
            # get realname 
            $Data{From} =~ s/<.*>|\(.*\)|\"|;|,//g;
            $Data{From} =~ s/( $)|(  $)//g;
            $Param{Salutation} =~ s/<OTRS_CUSTOMER_REALNAME>/$Data{From}/g;
        }
        # --
        # prepare signature
        # --
        $Param{Signature} = $QueueObject->GetSignature();
        $Param{Signature} =~ s/<OTRS_FIRST_NAME>/$Self->{UserFirstname}/g;
        $Param{Signature} =~ s/<OTRS_LAST_NAME>/$Self->{UserLastname}/g;
        # --
        # prepare body ...
        # --
        my $NewLine = $Self->{ConfigObject}->Get('ComposeTicketNewLine') || 75;
        $Data{Body} =~ s/(.{$NewLine}.+?\s)/$1\n/g;
        $Data{Body} =~ s/\n/\n> /g;
        $Data{Body} = "\n> " . $Data{Body};
        my @Body = split(/\n/, $Data{Body});
        $Data{Body} = '';
        foreach (1..4) {
            $Data{Body} .= $Body[$_]."\n" if ($Body[$_]);
        }
        # --
        # prepare from ...
        # --
        my %Address = $QueueObject->GetSystemAddress();
        $Data{From} = "$Address{RealName} <$Address{Email}>";
        $Data{Email} = $Address{Email};
        $Data{RealName} = $Address{RealName};

        # get next states
        my %NextStates = ();
        my $NextComposeTypePossibleTmp =
           $Self->{ConfigObject}->Get('DefaultNextBounceTypePossible')
               || die 'No Config entry "DefaultNextBounceTypePossible"!';
        my @NextComposeTypePossible = @$NextComposeTypePossibleTmp;
        foreach (@NextComposeTypePossible) {
            $NextStates{$Self->{TicketObject}->StateLookup(State => $_)} = $_;
        }

        # print form ...
        $Output .= $Self->{LayoutObject}->AgentBounce(
            %Param,
            %Data,
            TicketID => $Self->{TicketID},
            ArticleID => $Self->{ArticleID},
            NextStates => \%NextStates,
        );
        $Output .= $Self->{LayoutObject}->Footer();
    }
    elsif ($Self->{Subaction} eq 'Store') {
        foreach (qw(BounceTo To Subject Body InformSender BounceStateID)) {
            $Param{$_} = $Self->{ParamObject}->GetParam(Param => $_) || '';
        }
        # --
        # prepare from ...
        # --
        my %Address = $QueueObject->GetSystemAddress();
        $Param{From} = "$Address{RealName} <$Address{Email}>";
        $Param{Email} = $Address{Email};

        $Param{EmailPlain} = $Self->{ArticleObject}->GetPlain(ArticleID => $Self->{ArticleID});
        my $EmailObject = Kernel::System::EmailSend->new(
            ConfigObject => $Self->{ConfigObject},
            LogObject => $Self->{LogObject},
            DBObject => $Self->{DBObject},
        );
        if (!$EmailObject->Bounce(
            EmailPlain => $Param{EmailPlain},
            TicketObject => $Self->{TicketObject},
            TicketID => $Self->{TicketID},
            ArticleID => $Self->{ArticleID},
            UserID => $Self->{UserID},
            To => $Param{BounceTo},
            From => $Param{From},
            Email => $Param{Email},
            HistoryType => 'SendAnswer',
        )) {
           # error page 
           $Output = $Self->{LayoutObject}->Header(Title => 'Error');
           $Output .= $Self->{LayoutObject}->Error(
               Message => "Can't bounce email!",
               Comment => 'Please contact the admin.',
           );
           $Output .= $Self->{LayoutObject}->Footer();
           return $Output;
        }
        # --       
        # send customer info?
        # --
        if ($Param{InformSender}) {
            $Param{Body} =~ s/<OTRS_TICKET>/$Param{TicketNumber}/g;
            $Param{Body} =~ s/<OTRS_BOUNCE_TO>/$Param{BounceTo}/g;
            if (my $ArticleID = $EmailObject->Send(
              ArticleType => 'email-external',
              SenderType => 'agent',
              TicketID => $Self->{TicketID},
              HistoryType => 'Bounce',
              HistoryComment => "Bounced to '$Param{To}'.",
              From => $Param{From},
              Email => $Param{Email},
              To => $Param{To},
              Subject => $Param{Subject},
              UserID => $Self->{UserID},
              Body => $Param{Body},
              Charset => $Self->{UserCharset},
            )) {
              ###
            }
            else {
              # error page 
              $Output = $Self->{LayoutObject}->Header(Title => 'Error');
              $Output .= $Self->{LayoutObject}->Error(
                Message => "Can't send email!",
                Comment => 'Please contact the admin.',
              );
              $Output .= $Self->{LayoutObject}->Footer();
              return $Output;
            }
        }
        # --
        # set state
        # --
        my $NextState = $Self->{TicketObject}->StateIDLookup(StateID => $Param{BounceStateID});
        $Self->{TicketObject}->SetState(
            TicketID => $Self->{TicketID},
            ArticleID => $Self->{ArticleID},
            State => $NextState,
            UserID => $Self->{UserID},
          );
        # --
        # should i set an unlock?
        # --
        if ($NextState =~ /^close/i) {
          $Self->{TicketObject}->SetLock(
            TicketID => $Self->{TicketID},
            Lock => 'unlock',
            UserID => $Self->{UserID},
          );
        }
        # --
        # redirect
        # --
        $Output .= $Self->{LayoutObject}->Redirect(
            OP => "&Action=$NextScreen&QueueID=$Param{QueueID}&TicketID=$Self->{TicketID}",
        );
    }
    else {
        $Output .= $Self->{LayoutObject}->Header(Title => 'Error');
        $Output .= $Self->{LayoutObject}->Error(
            Message => 'Wrong Subaction!!',
            Comment => 'Please contact your admin',
        );
        $Output .= $Self->{LayoutObject}->Footer();
    }
    return $Output;
}
# --

1;
