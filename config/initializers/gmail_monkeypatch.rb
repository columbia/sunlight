## Monkey patching for the Gmail gem to add back features I need
module Gmail
  class Gmail::Message
    def fetch_email_data
      @email_data ||= @gmail.conn.uid_fetch(uid, ["RFC822",
                                                  'ENVELOPE',
                                                  'X-GM-LABELS',
                                                  'X-GM-THRID',
                                                  'X-GM-MSGID'])[0]
    end

    def msg_id
      fetch_email_data.attr["X-GM-MSGID"]
    end
  end
end
