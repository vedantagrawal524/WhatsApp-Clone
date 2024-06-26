import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:whatsapp/common/enums/message_enum.dart';
import 'package:whatsapp/common/providers/message_reply_to_provider.dart';
import 'package:whatsapp/common/repository/common_firebase_storage_repository.dart';
import 'package:whatsapp/common/utils/utils.dart';
import 'package:whatsapp/models/chat_contact.dart';
import 'package:whatsapp/models/group.dart';
import 'package:whatsapp/models/message.dart';
import 'package:whatsapp/models/user_model.dart';

final chatRepositoryProvider = Provider(
  (ref) => ChatRepository(
    firestore: FirebaseFirestore.instance,
    auth: FirebaseAuth.instance,
  ),
);

class ChatRepository {
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;

  ChatRepository({
    required this.firestore,
    required this.auth,
  });
//

  Stream<List<ChatContact>> getChatContacts() {
    return firestore
        .collection('users')
        .doc(auth.currentUser!.uid)
        .collection('chats')
        .snapshots()
        .asyncMap(
      (event) async {
        List<ChatContact> contacts = [];
        for (var document in event.docs) {
          var chatContact = ChatContact.fromMap(document.data());
          var userData = await firestore
              .collection('users')
              .doc(chatContact.contactId)
              .get();
          var user = UserModel.fromMap(userData.data()!);
          contacts.add(ChatContact(
            name: user.name,
            profilePic: user.profilePic,
            contactId: chatContact.contactId,
            timeSent: chatContact.timeSent,
            lastMessage: chatContact.lastMessage,
          ));
        }
        // contacts.sort((a, b) => a.timeSent.compareTo(b.timeSent));
        return contacts;
      },
    );
  }

  Stream<List<Group>> getchatGroups() {
    return firestore.collection('groups').snapshots().map(
      (event) {
        List<Group> groups = [];
        for (var document in event.docs) {
          var group = Group.fromMap(document.data());
          if (group.membersUid.contains(auth.currentUser!.uid)) {
            groups.add(group);
          }
        }
        // contacts.sort((a, b) => a.timeSent.compareTo(b.timeSent));
        return groups;
      },
    );
  }

  Stream<List<Message>> getChatStream(String receiverUserId) {
    return firestore
        .collection('users')
        .doc(auth.currentUser!.uid)
        .collection('chats')
        .doc(receiverUserId)
        .collection('messages')
        .orderBy('timeSent')
        .snapshots()
        .map(
      (event) {
        List<Message> messages = [];
        for (var document in event.docs) {
          var message = Message.fromMap(document.data());
          messages.add(message);
        }
        return messages;
      },
    );
  }

  Stream<List<Message>> getGroupChatStream(String groupId) {
    return firestore
        .collection('groups')
        .doc(groupId)
        .collection('chats')
        .orderBy('timeSent')
        .snapshots()
        .map(
      (event) {
        List<Message> messages = [];
        for (var document in event.docs) {
          var message = Message.fromMap(document.data());
          messages.add(message);
        }
        return messages;
      },
    );
  }

  void _saveDataToContactsSubcollection(
    String reciverUserId,
    UserModel senderUserData,
    UserModel? receiverUserData,
    String text,
    DateTime timeSent,
    bool isGroupChat,
  ) async {
    if (isGroupChat) {
      //(group) groups->groupId->lastMsg
      await firestore.collection('groups').doc(reciverUserId).update({
        'lastMessage': text,
        'lastMsgtimeSent': Timestamp.fromDate(DateTime.now()),
      });
    } else {
      //(Sender) users->senderId->chats->receiverId->setData
      var senderChatContact = ChatContact(
        name: receiverUserData!.name,
        profilePic: receiverUserData.profilePic,
        contactId: receiverUserData.uid,
        timeSent: timeSent,
        lastMessage: text,
      );
      await firestore
          .collection('users')
          .doc(senderUserData.uid)
          .collection('chats')
          .doc(receiverUserData.uid)
          .set(senderChatContact.toMap());
      //(Receiver) users->receiverId->chats->senderId->setData
      var receiverChatContact = ChatContact(
        name: senderUserData.name,
        profilePic: senderUserData.profilePic,
        contactId: senderUserData.uid,
        timeSent: timeSent,
        lastMessage: text,
      );
      await firestore
          .collection('users')
          .doc(receiverUserData.uid)
          .collection('chats')
          .doc(senderUserData.uid)
          .set(receiverChatContact.toMap());
    }
  }

  void _saveDataToMessageSubcollection({
    required String reciverUserId,
    required String text,
    required DateTime timeSent,
    required MessageEnum messageType,
    required String messageId,
    required String? reciverUserName,
    required String senderUserName,
    required MessageReplyTo? messageReplyTo,
    required bool isGroupChat,
  }) async {
    final message = Message(
      senderId: auth.currentUser!.uid,
      reciverUserId: reciverUserId,
      text: text,
      type: messageType,
      timeSent: timeSent,
      messageId: messageId,
      isSeen: false,
      repliedToMessage: messageReplyTo == null ? '' : messageReplyTo.message,
      repliedToUser: messageReplyTo == null
          ? ''
          : messageReplyTo.isMe
              ? senderUserName
              : reciverUserName ?? '',
      replyToType: messageReplyTo == null
          ? MessageEnum.text
          : messageReplyTo.messageType,
    );

    if (isGroupChat) {
      //(group) groups->groupId->chats->messageId->Msg
      await firestore
          .collection('groups')
          .doc(reciverUserId)
          .collection('chats')
          .doc(messageId)
          .set(message.toMap());
    } else {
      //(Sender) users->senderId->chats->receiverId->messages->messageId->storeData
      await firestore
          .collection('users')
          .doc(auth.currentUser!.uid)
          .collection('chats')
          .doc(reciverUserId)
          .collection('messages')
          .doc(messageId)
          .set(message.toMap());
      //(Receiver) users->receiverId->chats->senderId->messages->messageId->storeData
      await firestore
          .collection('users')
          .doc(reciverUserId)
          .collection('chats')
          .doc(auth.currentUser!.uid)
          .collection('messages')
          .doc(messageId)
          .set(message.toMap());
    }
  }

  void sendTextMessage({
    required BuildContext context,
    required String text,
    required String receiverUserId,
    required UserModel sendUser,
    required MessageReplyTo? messageReplyTo,
    required bool isGroupChat,
  }) async {
    try {
      var timeSent = DateTime.now();
      UserModel? receiverUserData;

      if (!isGroupChat) {
        var userDataMap =
            await firestore.collection('users').doc(receiverUserId).get();
        receiverUserData = UserModel.fromMap(userDataMap.data()!);
      }

      var messageId = const Uuid().v1();

      _saveDataToContactsSubcollection(
        receiverUserId,
        sendUser,
        receiverUserData,
        text,
        timeSent,
        isGroupChat,
      );

      _saveDataToMessageSubcollection(
        reciverUserId: receiverUserId,
        text: text,
        timeSent: timeSent,
        messageType: MessageEnum.text,
        messageId: messageId,
        reciverUserName: receiverUserData?.name,
        senderUserName: sendUser.name,
        messageReplyTo: messageReplyTo,
        isGroupChat: isGroupChat,
      );
    } catch (e) {
      showSnackBar(context: context, content: e.toString());
    }
  }

  void sendFileMessag({
    required BuildContext context,
    required File file,
    required String receiverUserId,
    required UserModel senderUserData,
    required ProviderRef ref,
    required MessageEnum messagetype,
    required MessageReplyTo? messageReplyTo,
    required bool isGroupChat,
  }) async {
    try {
      var timeSent = DateTime.now();
      var messageId = const Uuid().v1();

      String fileUrl = await ref
          .read(commonFirebaseStorageRepositoryProvider)
          .storeFileToFirebase(
            'chat/${senderUserData.uid}/$receiverUserId/${messagetype.type}/$messageId',
            file,
          );

      UserModel? receiverUserData;
      if (!isGroupChat) {
        var userDataMap =
            await firestore.collection('users').doc(receiverUserId).get();
        receiverUserData = UserModel.fromMap(userDataMap.data()!);
      }
      String contactMsg;
      switch (messagetype) {
        case MessageEnum.image:
          contactMsg = '📷 Photo';
          break;
        case MessageEnum.video:
          contactMsg = '🎥 Video';
          break;
        case MessageEnum.audio:
          contactMsg = '🎵 Audio';
          break;
        case MessageEnum.gif:
          contactMsg = 'GIF';
          break;
        default:
          contactMsg = 'Text';
      }

      _saveDataToContactsSubcollection(
        receiverUserId,
        senderUserData,
        receiverUserData,
        contactMsg,
        timeSent,
        isGroupChat,
      );
      _saveDataToMessageSubcollection(
        reciverUserId: receiverUserId,
        text: fileUrl,
        timeSent: timeSent,
        messageType: messagetype,
        messageId: messageId,
        reciverUserName: receiverUserData?.name,
        senderUserName: senderUserData.name,
        messageReplyTo: messageReplyTo,
        isGroupChat: isGroupChat,
      );
    } catch (e) {
      showSnackBar(context: context, content: e.toString());
    }
  }

  void sendGIFMessage({
    required BuildContext context,
    required String gifUrl,
    required String receiverUserId,
    required UserModel sendUser,
    required MessageReplyTo? messageReplyTo,
    required bool isGroupChat,
  }) async {
    try {
      var timeSent = DateTime.now();
      UserModel? receiverUserData;
      if (!isGroupChat) {
        var userDataMap =
            await firestore.collection('users').doc(receiverUserId).get();
        receiverUserData = UserModel.fromMap(userDataMap.data()!);
      }
      var messageId = const Uuid().v1();

      _saveDataToContactsSubcollection(
        receiverUserId,
        sendUser,
        receiverUserData,
        'GIF',
        timeSent,
        isGroupChat,
      );

      _saveDataToMessageSubcollection(
        reciverUserId: receiverUserId,
        text: gifUrl,
        timeSent: timeSent,
        messageType: MessageEnum.gif,
        messageId: messageId,
        reciverUserName: receiverUserData?.name,
        senderUserName: sendUser.name,
        messageReplyTo: messageReplyTo,
        isGroupChat: isGroupChat,
      );
    } catch (e) {
      showSnackBar(context: context, content: e.toString());
    }
  }

  void setMessageSeen(
    BuildContext context,
    String receiverUserId,
    String messageId,
  ) async {
    try {
      await firestore
          .collection('users')
          .doc(auth.currentUser!.uid)
          .collection('chats')
          .doc(receiverUserId)
          .collection('messages')
          .doc(messageId)
          .update({'isSeen': true});

      await firestore
          .collection('users')
          .doc(receiverUserId)
          .collection('chats')
          .doc(auth.currentUser!.uid)
          .collection('messages')
          .doc(messageId)
          .update({'isSeen': true});
    } catch (e) {
      showSnackBar(context: context, content: e.toString());
    }
  }
}
